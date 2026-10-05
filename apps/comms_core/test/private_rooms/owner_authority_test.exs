defmodule CommsCore.PrivateRooms.OwnerAuthorityTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Conversations, Messaging, Repo}

  alias CommsCore.Accounts.{
    MatrixIdentity,
    MatrixClientSession,
    MatrixCredentials,
    MatrixProvisioningReceipt,
    Session
  }

  alias CommsCore.Conversations.{PrivateRoom, PrivateRoomControlReceipt}
  alias CommsCore.Messaging.{PrivateEvent, PrivateEventReceipt}
  alias CommsTestSupport.Fixtures
  @moduletag :integration

  # These adapters isolate application authority/receipts, not cryptography.
  # Actual maintained SDK encryption/SAS is exercised by the separate live gate.
  defmodule IdentityProvider do
    @behaviour CommsCore.Accounts.MatrixProvisioningPort.Contract
    def execute(:provision, c),
      do: {:ok, %MatrixProvisioningReceipt{matrix_user_id: c.matrix_user_id}}

    def execute(action, c) when action in [:login, :refresh] do
      if Process.get(:identity_unknown_ack),
        do: {:error, :matrix_provider_unavailable},
        else:
          {:ok,
           %MatrixProvisioningReceipt{
             matrix_user_id: c.matrix_user_id,
             matrix_device_id: c.matrix_device_id,
             access_token: "provider-client-auth",
             refresh_token: "provider-refresh-auth",
             expires_in_ms: 180_000
           }}
    end

    def execute(:revoke, c),
      do:
        {:ok,
         %MatrixProvisioningReceipt{
           matrix_user_id: c.matrix_user_id,
           matrix_device_id: c.matrix_device_id,
           revoked?: true
         }}
  end

  defmodule RoomProvider do
    @behaviour CommsCore.Conversations.PrivateRoomControlPort.Contract
    def execute(action, c) do
      send(self(), {:native_control, action, c.conversation_id})

      case action do
        :provision ->
          {:ok,
           %PrivateRoomControlReceipt{matrix_room_id: "!" <> c.conversation_id <> ":example.test"}}

        :remove_member ->
          if Process.get(:ban_unknown_ack, false) or
               c.removed_matrix_user_id == Process.get(:uncertain_removed_identity),
             do: {:error, :private_member_removal_unconfirmed},
             else: {:ok, %PrivateRoomControlReceipt{matrix_room_id: c.matrix_room_id}}

        :purge ->
          {:ok,
           %PrivateRoomControlReceipt{
             matrix_room_id: c.matrix_room_id,
             purge_id: "purge-proof",
             provider_purged?: false
           }}

        :purge_status ->
          {:ok,
           %PrivateRoomControlReceipt{
             matrix_room_id: c.matrix_room_id,
             purge_id: c.purge_id,
             provider_purged?: true
           }}
      end
    end
  end

  defmodule EventProvider do
    @behaviour CommsCore.Messaging.PrivateEventPort.Contract
    def send_encrypted(c) do
      send(self(), {:native_encrypted_send, c.transaction_id})

      cond do
        Process.get(:event_unknown_ack) ->
          {:error, :private_event_provider_unavailable}

        Process.get(:forged_native_sender) ->
          {:ok,
           %PrivateEventReceipt{
             matrix_room_id: c.grant.matrix_room_id,
             matrix_sender: "@foreign:example.test",
             matrix_event_id: "$" <> c.transaction_id,
             content: c.content
           }}

        true ->
          {:ok,
           %PrivateEventReceipt{
             matrix_room_id: c.grant.matrix_room_id,
             matrix_sender: c.grant.matrix_user_id,
             matrix_event_id: "$" <> c.transaction_id,
             content: c.content
           }}
      end
    end
  end

  setup do
    settings = %{
      matrix_client_provisioning_enabled: true,
      private_rooms_enabled: true,
      matrix_provisioning_adapter: IdentityProvider,
      private_room_control_adapter: RoomProvider,
      private_event_adapter: EventProvider,
      identity_secret_encryption_key: :crypto.strong_rand_bytes(32),
      matrix_identity_provider: %{
        issuer: "https://matrix.example.test",
        server_name: "example.test",
        control_user_id: "@control:example.test"
      }
    }

    previous = Enum.map(settings, fn {k, _} -> {k, Application.fetch_env(:comms_core, k)} end)
    Enum.each(settings, fn {k, v} -> Application.put_env(:comms_core, k, v) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:comms_core, k, v)
        {k, :error} -> Application.delete_env(:comms_core, k)
      end)
    end)

    account =
      Fixtures.account_fixture(%{
        tenant_slug: "private-owner-" <> String.replace(Ecto.UUID.generate(), "-", ""),
        password: "private-test-owner-password"
      })

    %{user: peer} = Fixtures.user_fixture(account)

    peer_subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(account, peer, "Private peer")

    owner = Fixtures.subject(account)
    {:ok, _} = Accounts.matrix_client_session(owner)
    {:ok, _} = Accounts.matrix_client_session(peer_subject)
    %{account: account, peer: peer, owner: owner, peer_subject: peer_subject}
  end

  test "enrollment lookup is ready-only and token-free; client credential envelope is tuple-bound",
       c do
    {:ok, identity} = Accounts.matrix_identity_view(c.account.tenant.id, c.account.user.id)
    assert identity.issuer == "https://matrix.example.test"
    refute Map.has_key?(Map.from_struct(identity), :access_token)
    {:ok, view} = Accounts.matrix_client_session(c.owner)
    refute inspect(view) =~ view.access_token
    retained = Repo.get_by!(MatrixClientSession, session_id: c.owner.session_id)

    assert {:ok, %{"access_token" => "provider-client-auth"}} =
             MatrixCredentials.open(retained.credential_secret, retained)

    assert {:error, :matrix_credential_unavailable} =
             MatrixCredentials.open(retained.credential_secret, %{
               retained
               | tenant_id: Ecto.UUID.generate()
             })

    identity_row = Repo.get_by!(MatrixIdentity, user_id: c.peer.id)
    Repo.update!(Ecto.Changeset.change(identity_row, state: :pending))
    assert {:error, :not_found} = Accounts.matrix_identity_view(c.account.tenant.id, c.peer.id)
  end

  test "a new private room preserves the existing readable conversation and rejects plaintext capture",
       c do
    room = create!(c)
    assert Repo.get!(CommsCore.Conversations.Conversation, room.id).content_mode == :matrix_e2ee

    assert Repo.get!(CommsCore.Conversations.Conversation, c.account.conversation.id).content_mode ==
             :server_readable

    assert {:error, :private_room_requires_encrypted_client} =
             Conversations.authorize_send_message(room.id, c.owner)

    assert {:error, :private_room_requires_encrypted_client} =
             Conversations.authorize_use_whiteboard(room.id, c.owner)

    assert {:error, :forbidden} =
             Conversations.call_membership(c.account.tenant.id, room.id, c.account.user.id)
  end

  test "unknown native ACK remains an exact pending intent; changed ciphertext conflicts and duplicate receipt is reused",
       c do
    room = create!(c)
    attrs = event(room, "unknown-ack")
    Process.put(:event_unknown_ack, true)

    assert {:error, :private_event_provider_unavailable} =
             Messaging.send_private_event(room.id, attrs, c.owner)

    assert Repo.get_by!(PrivateEvent, transaction_id: "unknown-ack").state == :pending
    {:ok, page} = Messaging.replay_private_events(room.id, query(room), c.owner)
    assert [%{transaction_id: "unknown-ack", content: content}] = page.pending_intents
    assert content == attrs.content

    assert {:error, :idempotency_conflict} =
             Messaging.send_private_event(
               room.id,
               %{
                 attrs
                 | content:
                     Map.put(
                       attrs.content,
                       "ciphertext",
                       Base.encode64(:binary.copy(<<2>>, 48), padding: false)
                     )
               },
               c.owner
             )

    Process.delete(:event_unknown_ack)
    assert {:ok, %{replayed: false}} = Messaging.send_private_event(room.id, attrs, c.owner)
    assert {:ok, %{replayed: true}} = Messaging.send_private_event(room.id, attrs, c.owner)

    assert Repo.aggregate(from(e in PrivateEvent, where: e.conversation_id == ^room.id), :count) ==
             1
  end

  test "a forged native sender cannot become trusted author lineage", c do
    room = create!(c)
    Process.put(:forged_native_sender, true)

    assert {:error, :private_event_provider_receipt_invalid} =
             Messaging.send_private_event(room.id, event(room, "forged"), c.owner)

    retained = Repo.get_by!(PrivateEvent, transaction_id: "forged")
    assert retained.author_user_id == c.account.user.id
    assert retained.state == :pending
    assert retained.matrix_event_id == nil
  end

  test "removal persists its fence through unknown ACK; removed user and old intents cannot replay or send",
       c do
    room = create!(c)
    assert {:ok, _} = Messaging.send_private_event(room.id, event(room, "old-history"), c.owner)
    Process.put(:event_unknown_ack, true)
    assert {:error, _} = Messaging.send_private_event(room.id, event(room, "old-intent"), c.owner)
    Process.delete(:event_unknown_ack)
    Process.put(:ban_unknown_ack, true)

    assert {:error, :private_member_removal_unconfirmed} =
             Conversations.remove_private_room_member(
               room.id,
               c.peer.id,
               %{membership_epoch: 1},
               c.owner
             )

    retained = Repo.get_by!(PrivateRoom, conversation_id: room.id)
    assert retained.state == :rekey_pending
    assert retained.generation == 2
    assert c.peer.id in retained.historical_user_ids
    assert {:error, :forbidden} = Conversations.private_room(room.id, c.peer_subject)

    assert {:error, :private_room_rekey_pending} =
             Messaging.send_private_event(room.id, event(room, "new"), c.owner)

    Process.delete(:ban_unknown_ack)

    {:ok, updated} =
      Conversations.remove_private_room_member(
        room.id,
        c.peer.id,
        %{membership_epoch: 1},
        c.owner
      )

    assert updated.state == :active
    {:ok, page} = Messaging.replay_private_events(room.id, query(updated), c.owner)
    assert length(page.events) == 1
    assert page.pending_intents == []

    assert {:error, :private_room_generation_stale} =
             Messaging.send_private_event(room.id, event(room, "old-intent"), c.owner)
  end

  test "expired retained K session refuses opaque effects before native provider", c do
    room = create!(c)

    Repo.update_all(from(s in Session, where: s.id == ^c.owner.session_id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, :forbidden} =
             Messaging.send_private_event(room.id, event(room, "expired"), c.owner)

    refute_received {:native_encrypted_send, "expired"}

    assert Repo.aggregate(from(e in PrivateEvent, where: e.conversation_id == ^room.id), :count) ==
             0
  end

  test "historical participant erasure fences the whole derived room; unrelated room survives and completion remains pending",
       c do
    room = create!(c)
    %{user: unrelated} = Fixtures.user_fixture(c.account)

    unrelated_subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(
        c.account,
        unrelated,
        "Unrelated private peer"
      )

    {:ok, _} = Accounts.matrix_client_session(unrelated_subject)

    {:ok, other} =
      Conversations.create_private_room(
        %{id: Ecto.UUID.generate(), title: "Unaffected room", member_ids: [unrelated.id]},
        c.owner
      )

    {:ok, _} =
      Conversations.remove_private_room_member(
        room.id,
        c.peer.id,
        %{membership_epoch: 1},
        c.owner
      )

    assert {:ok, {:ok, %{private_rooms_fenced: 1}}} =
             Repo.transaction(fn ->
               Conversations.prepare_private_room_erasure(c.account.tenant.id, :user, c.peer.id)
             end)

    assert Repo.get_by!(PrivateRoom, conversation_id: room.id).state == :purge_pending
    assert Repo.get_by!(PrivateRoom, conversation_id: other.id).state == :active

    assert {:ok, true} =
             Conversations.private_room_erasure_pending?(c.account.tenant.id, :user, c.peer.id)

    worker = CommsCore.RuntimePorts.job_worker!(:private_room_purge_reconciler)
    assert {:ok, %{provider_purged: 0}} = Conversations.reconcile_private_room_purges(worker)
    assert {:ok, %{provider_purged: 1}} = Conversations.reconcile_private_room_purges(worker)
    assert Repo.get_by!(PrivateRoom, conversation_id: room.id).state == :provider_purged

    assert {:ok, true} =
             Conversations.private_room_erasure_pending?(c.account.tenant.id, :user, c.peer.id)

    assert Repo.get_by!(PrivateRoom, conversation_id: room.id).key_cleanup_state == "unconfirmed"
  end

  test "legal hold blocks erasure and invented native purge proof cannot wipe pending ciphertext",
       c do
    room = create!(c)
    Process.put(:event_unknown_ack, true)

    assert {:error, _} =
             Messaging.send_private_event(room.id, event(room, "retained-pending"), c.owner)

    Repo.insert!(%CommsCore.Governance.LegalHold{
      tenant_id: c.account.tenant.id,
      created_by_user_id: c.account.user.id,
      subject_user_id: c.peer.id,
      name: "Private legal hold",
      reason: "Preserve all governed room derivatives",
      scope_type: :user,
      status: :active,
      starts_at: DateTime.utc_now()
    })

    assert {:error, :legal_hold_active} =
             Repo.transaction(fn ->
               Conversations.prepare_private_room_erasure(c.account.tenant.id, :user, c.peer.id)
             end)

    assert Repo.get_by!(PrivateRoom, conversation_id: room.id).state == :active

    proof = %CommsCore.Conversations.PrivateContentErasureCommand{
      tenant_id: c.account.tenant.id,
      conversation_id: room.id,
      generation: 1,
      matrix_room_id: room.matrix_room_id,
      provider_purge_id: "invented",
      timestamp: DateTime.utc_now()
    }

    assert {:error, :legal_hold_active} =
             Repo.transaction(fn -> Messaging.erase_private_content(proof) end)

    assert Repo.get_by!(PrivateEvent, transaction_id: "retained-pending").content
  end

  test "a Matrix identity without any private room still fences erasure and retains unknown backup cleanup",
       c do
    refute Repo.exists?(PrivateRoom)

    assert :ok =
             Repo.transaction(fn ->
               Accounts.prepare_matrix_identity_erasure(c.account.tenant.id, c.peer.id)
             end)
             |> elem(1)

    assert Accounts.matrix_identity_erasure_pending?(c.account.tenant.id, c.peer.id)
    assert {:error, :matrix_identity_withdrawn} = Accounts.matrix_client_session(c.peer_subject)
    identity = Repo.get_by!(MatrixIdentity, user_id: c.peer.id)
    assert identity.state == :cleanup_pending
    assert identity.erasure_requested_at
    assert identity.key_cleanup_state == "unconfirmed"
    worker = CommsCore.RuntimePorts.job_worker!(:matrix_device_reconciler)
    assert {:ok, %{revoked: 1}} = Accounts.reconcile_matrix_devices(worker)
    assert Repo.get_by!(MatrixClientSession, user_id: c.peer.id).state == :revoked
    assert Repo.get!(MatrixIdentity, identity.id).auth_secret == nil
    assert Accounts.matrix_identity_erasure_pending?(c.account.tenant.id, c.peer.id)
  end

  test "User lifecycle withdrawal fences room membership and session cleanup before any native ban",
       c do
    assert {:ok, _} =
             Accounts.step_up_view(%{current_password: "private-test-owner-password"}, c.owner)

    room = create!(c)

    assert {:ok, _} =
             Accounts.change_user(
               c.peer.id,
               %{
                 status: :suspended,
                 reason: "Withdraw participant eligibility",
                 version: c.peer.lock_version
               },
               c.owner
             )

    retained = Repo.get_by!(PrivateRoom, conversation_id: room.id)
    assert retained.state == :rekey_pending
    assert retained.membership_epoch == 2
    assert retained.generation == 2
    assert length(retained.pending_removed_matrix_user_ids) == 1
    assert Repo.get_by!(MatrixClientSession, user_id: c.peer.id).state == :cleanup_pending
    assert {:error, :not_found} = Accounts.matrix_identity_view(c.account.tenant.id, c.peer.id)
    assert {:error, :forbidden} = Conversations.private_room(room.id, c.peer_subject)

    assert {:error, :private_room_rekey_pending} =
             Messaging.send_private_event(
               room.id,
               %{event(room, "after-withdrawal") | generation: 2, membership_epoch: 2},
               c.owner
             )

    worker = CommsCore.RuntimePorts.job_worker!(:private_room_purge_reconciler)
    assert {:ok, _} = Conversations.reconcile_private_room_purges(worker)
    assert {:ok, refreshed} = Conversations.private_room(room.id, c.owner)
    assert refreshed.state == :active
    refute Enum.any?(refreshed.members, &(&1.user_id == c.peer.id))
  end

  test "an uncertain manual ban and a second lifecycle withdrawal must both drain before reactivation",
       c do
    %{user: other} = Fixtures.user_fixture(c.account)

    other_subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(
        c.account,
        other,
        "Third private participant"
      )

    {:ok, _} = Accounts.matrix_client_session(other_subject)

    {:ok, room} =
      Conversations.create_private_room(
        %{
          id: Ecto.UUID.generate(),
          title: "Mixed durable removals",
          member_ids: [c.peer.id, other.id]
        },
        c.owner
      )

    Process.put(:ban_unknown_ack, true)

    assert {:error, :private_member_removal_unconfirmed} =
             Conversations.remove_private_room_member(
               room.id,
               c.peer.id,
               %{membership_epoch: 1},
               c.owner
             )

    Process.delete(:ban_unknown_ack)
    retained = Repo.get_by!(PrivateRoom, conversation_id: room.id)
    uncertain = retained.pending_removed_matrix_user_id
    Process.put(:uncertain_removed_identity, uncertain)

    assert {:ok, _} =
             Accounts.step_up_view(%{current_password: "private-test-owner-password"}, c.owner)

    assert {:ok, _} =
             Accounts.change_user(
               other.id,
               %{
                 status: :suspended,
                 version: other.lock_version,
                 reason: "Withdraw second participant"
               },
               c.owner
             )

    worker = CommsCore.RuntimePorts.job_worker!(:private_room_purge_reconciler)
    assert {:ok, _} = Conversations.reconcile_private_room_purges(worker)
    still_fenced = Repo.get_by!(PrivateRoom, conversation_id: room.id)
    assert still_fenced.state == :rekey_pending
    assert uncertain in still_fenced.pending_removed_matrix_user_ids
    assert still_fenced.pending_removed_matrix_user_id == uncertain
    Process.delete(:uncertain_removed_identity)
    assert {:ok, _} = Conversations.reconcile_private_room_purges(worker)
    drained = Repo.get_by!(PrivateRoom, conversation_id: room.id)
    assert drained.state == :active
    assert drained.pending_removed_matrix_user_ids == []
    assert drained.pending_removed_matrix_user_id == nil
  end

  defp create!(c) do
    {:ok, room} =
      Conversations.create_private_room(
        %{id: Ecto.UUID.generate(), title: "Explicit private room", member_ids: [c.peer.id]},
        c.owner
      )

    room
  end

  defp query(room),
    do: %{membership_epoch: room.membership_epoch, generation: room.generation, after_sequence: 0}

  defp event(room, txn),
    do: %{
      membership_epoch: room.membership_epoch,
      generation: room.generation,
      transaction_id: txn,
      content: %{
        "algorithm" => "m.megolm.v1.aes-sha2",
        "session_id" => Base.encode64(:binary.copy(<<1>>, 32), padding: false),
        "ciphertext" => Base.encode64(:binary.copy(<<1>>, 48), padding: false)
      }
    }
end
