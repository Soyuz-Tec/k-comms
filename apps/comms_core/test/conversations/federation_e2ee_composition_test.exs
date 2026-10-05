defmodule CommsCore.Conversations.FederationE2EECompositionTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Messaging, Repo, RuntimePorts, ServiceAccounts}
  alias CommsCore.Accounts.{MatrixClientSession, Session, User}
  alias CommsCore.Conversations.{Membership, PrivateRoom}

  alias CommsCore.Conversations.Federation.{
    Command,
    Participant,
    ProviderReceipt,
    Room,
    SecretBox
  }

  alias CommsCore.Accounts.MatrixProvisioningReceipt
  alias CommsCore.Conversations.PrivateRoomControlReceipt
  alias CommsTestSupport.Fixtures
  @moduletag :integration

  defmodule IdentityProvider do
    @behaviour CommsCore.Accounts.MatrixProvisioningPort.Contract
    def execute(:provision, command) do
      if Process.get(:federation_identity_unknown_ack),
        do: {:error, :matrix_provider_unavailable},
        else: {:ok, %MatrixProvisioningReceipt{matrix_user_id: command.matrix_user_id}}
    end

    def execute(action, command) when action in [:login, :refresh],
      do:
        {:ok,
         %MatrixProvisioningReceipt{
           matrix_user_id: command.matrix_user_id,
           matrix_device_id: command.matrix_device_id,
           access_token: "synthetic-client-auth-token",
           refresh_token: "synthetic-client-refresh-token",
           expires_in_ms: 180_000
         }}
  end

  defmodule RoomProvider do
    @behaviour CommsCore.Conversations.PrivateRoomControlPort.Contract
    def execute(:provision, command),
      do:
        {:ok,
         %PrivateRoomControlReceipt{
           matrix_room_id: "!" <> command.conversation_id <> ":example.org"
         }}
  end

  defmodule BridgeProvider do
    @behaviour CommsCore.Conversations.Federation.ProviderPort
    def perform(request) do
      send(self(), {:federation_effect, request.operation, request.transaction_id})
      {:error, :unexpected_federation_effect}
    end
  end

  # These maintained owner ports simulate missing ACKs without native HTTP.
  # Current authority, withdrawal, queued jobs and cleanup persistence stay real.
  defmodule WithdrawalBridgeProvider do
    @behaviour CommsCore.Conversations.Federation.ProviderPort

    def perform(request) do
      effects = Process.get(:scim_federation_effects, [])
      Process.put(:scim_federation_effects, [request | effects])

      case request.operation do
        :create ->
          {:ok, %ProviderReceipt{operation: :create, room_id: "!scim-bridge:example.org"}}

        :invite ->
          {:ok, %ProviderReceipt{operation: :invite, state: "joined"}}

        :send ->
          if request.transaction_id == Process.get(:scim_uncertain_send),
            do: {:error, :federation_send_outcome_unconfirmed},
            else:
              {:ok,
               %ProviderReceipt{operation: :send, event_id: "$scim-" <> request.transaction_id}}

        :recover_event ->
          {:error, :federation_send_outcome_unconfirmed}

        :leave ->
          {:ok, %ProviderReceipt{operation: :leave, local_absence_observed: true}}

        _ ->
          {:error, :unexpected_federation_effect}
      end
    end
  end

  defmodule WithdrawalRoomProvider do
    @behaviour CommsCore.Conversations.PrivateRoomControlPort.Contract

    def execute(:provision, command),
      do:
        {:ok,
         %PrivateRoomControlReceipt{
           matrix_room_id: "!" <> command.conversation_id <> ":example.org"
         }}

    def execute(:remove_member, command) do
      send(self(), {:scim_private_ban, command.removed_matrix_user_id})
      {:error, :private_member_removal_unconfirmed}
    end

    def execute(_action, _command), do: {:error, :unexpected_private_control_effect}
  end

  defmodule ForbiddenPrivateEventProvider do
    @behaviour CommsCore.Messaging.PrivateEventPort.Contract

    def send_encrypted(command) do
      send(self(), {:scim_unexpected_private_send, command.transaction_id})
      {:error, :private_event_provider_unavailable}
    end
  end

  setup do
    settings = %{
      federation_enabled: true,
      federation_envelope_key: :crypto.strong_rand_bytes(32),
      federation_homeserver_origin: "https://matrix.example.org",
      federation_server_name: "example.org",
      federation_bridge_user: "@bridge:example.org",
      federation_provider_adapter: BridgeProvider,
      matrix_client_provisioning_enabled: true,
      private_rooms_enabled: true,
      matrix_provisioning_adapter: IdentityProvider,
      private_room_control_adapter: RoomProvider,
      identity_secret_encryption_key: :crypto.strong_rand_bytes(32),
      matrix_identity_provider: %{
        issuer: "https://matrix.example.org",
        server_name: "example.org",
        control_user_id: "@control:example.org"
      }
    }

    previous =
      Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, _} =
             Conversations.put_federation_trust(
               %{
                 domain: "remote.example.org",
                 residency: "Synthetic region",
                 cross_border_reason: "Reviewed synthetic federation processing",
                 enabled: true
               },
               subject
             )

    %{account: account, subject: subject}
  end

  test "admission uses the actual ready-only Identity owner and preserves immutable provider control",
       c do
    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    assert Conversations.rollback_federation_hazard_count() == 1
    assert {:ok, _} = Accounts.matrix_client_session(c.subject)
    assert {:ok, identity} = Accounts.matrix_identity_view(c.account.tenant.id, c.account.user.id)
    assert identity.provisioning_state == :ready

    assert {:error, :not_found} =
             Accounts.matrix_identity_view(Ecto.UUID.generate(), c.account.user.id)

    Application.put_env(
      :comms_core,
      :federation_homeserver_origin,
      "https://replacement.example.org"
    )

    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    Application.put_env(:comms_core, :federation_homeserver_origin, "https://matrix.example.org")
    Application.put_env(:comms_core, :federation_server_name, "replacement.example.org")
    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    Application.put_env(:comms_core, :federation_server_name, "example.org")
    assert {:ok, room} = create_bridge(c)
    assert room.conversation_id == c.account.conversation.id
    refute Map.has_key?(Map.from_struct(room), :provider_bridge_user)
    refute Map.has_key?(Map.from_struct(room), :access_token)
    refute_received {:federation_effect, _, _}
  end

  test "unknown identity provisioning ACK cannot admit a plaintext bridge", c do
    Process.put(:federation_identity_unknown_ack, true)
    assert {:error, _} = Accounts.matrix_client_session(c.subject)

    assert {:error, :not_found} =
             Accounts.matrix_identity_view(c.account.tenant.id, c.account.user.id)

    assert {:error, :matrix_identity_not_ready} = create_bridge(c)
    assert Conversations.rollback_federation_hazard_count() == 1
    refute_received {:federation_effect, _, _}
  end

  test "actual private-room owner creation denies every plaintext Federation operation without writes",
       c do
    assert {:ok, _} = Accounts.matrix_client_session(c.subject)
    peer = Fixtures.user_fixture(c.account)

    peer_subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(
        c.account,
        peer.user,
        "Federation private peer"
      )

    assert {:ok, _} = Accounts.matrix_client_session(peer_subject)

    assert {:ok, private} =
             Conversations.create_private_room(
               %{
                 id: Ecto.UUID.generate(),
                 title: "Synthetic encrypted room",
                 member_ids: [peer.user.id]
               },
               c.subject
             )

    assert {:ok, conversation} = Conversations.get_for_user_view(private.id, c.subject)
    assert conversation.content_mode == :matrix_e2ee
    count = Conversations.rollback_federation_hazard_count()

    assert {:error, :encrypted_conversation_bridge_refused} = create_bridge(c, private.id)

    assert {:error, :private_room_requires_encrypted_client} =
             Conversations.federation_room(private.id, c.subject)

    assert {:error, :not_found} =
             Conversations.send_federation_message(
               private.id,
               %{
                 version: 1,
                 body: "plaintext must not cross",
                 idempotency_key: Ecto.UUID.generate()
               },
               c.subject
             )

    assert {:error, :not_found} =
             Conversations.invite_federation_participant(
               private.id,
               %{
                 version: 1,
                 matrix_user_id: "@person:remote.example.org"
               },
               c.subject
             )

    assert {:error, :not_found} = Conversations.federation_timeline(private.id, %{}, c.subject)
    assert {:error, :not_found} = Conversations.export_federation_metadata(private.id, c.subject)
    assert Conversations.rollback_federation_hazard_count() == count
    refute_received {:federation_effect, _, _}
  end

  @tag :scim_federation_composition
  test "SCIM suspension composes native and private withdrawal with Federation cancellation", c do
    # Keep the configured composition real; only remote provider ports are isolated.
    assert Application.fetch_env!(:comms_core, :identity_call_lifecycle_adapter) ==
             CommsCore.AudioCalls.LifecycleCoordinator

    assert Application.fetch_env!(:comms_core, :matrix_eligibility_adapter) ==
             CommsCore.Conversations.PrivateRoomEligibility

    providers = %{
      federation_provider_adapter: WithdrawalBridgeProvider,
      private_room_control_adapter: WithdrawalRoomProvider,
      private_event_adapter: ForbiddenPrivateEventProvider
    }

    previous =
      Enum.map(providers, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)

    Enum.each(providers, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    assert {:ok, _} = Accounts.matrix_client_session(c.subject)
    %{user: peer} = Fixtures.user_fixture(c.account)

    peer_subject =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(
        c.account,
        peer,
        "SCIM bridge peer"
      )

    assert {:ok, _} = Accounts.matrix_client_session(peer_subject)
    native = Repo.get_by!(MatrixClientSession, session_id: peer_subject.session_id)
    owner_native = Repo.get_by!(MatrixClientSession, session_id: c.subject.session_id)

    assert {:ok, private} =
             Conversations.create_private_room(
               %{id: Ecto.UUID.generate(), title: "SCIM encrypted room", member_ids: [peer.id]},
               c.subject
             )

    original_private = Repo.get_by!(PrivateRoom, conversation_id: private.id)

    assert {:ok, plain} =
             Conversations.create_view(
               %{kind: :group, title: "SCIM plaintext bridge", member_ids: [peer.id]},
               c.subject
             )

    assert {:ok, bridge} = create_bridge(c, plain.id)
    create = Repo.get_by!(Command, room_id: bridge.id, kind: "create")
    worker = RuntimePorts.job_worker!(:federation_command)
    assert :ok = worker.perform(%Oban.Job{args: %{"command_id" => create.id}})
    assert {:ok, active} = Conversations.federation_room(plain.id, c.subject)
    assert active.status == "active"

    assert {:ok, consented} =
             Conversations.federation_consent(
               plain.id,
               %{
                 version: active.version,
                 accept: true,
                 plaintext_disclosure_accepted: true
               },
               peer_subject
             )

    owner_participant = Repo.get_by!(Participant, room_id: bridge.id, user_id: c.account.user.id)
    original_bridge = Repo.get!(Room, bridge.id)

    assert {:ok, uncertain} =
             Conversations.send_federation_message(
               plain.id,
               %{
                 version: consented.version,
                 body: "Synthetic send whose native ACK is unknown",
                 idempotency_key: Ecto.UUID.generate()
               },
               peer_subject
             )

    Process.put(:scim_uncertain_send, uncertain.id)

    assert {:error, :federation_send_outcome_unconfirmed} =
             worker.perform(%Oban.Job{args: %{"command_id" => uncertain.id}})

    assert Repo.get!(Command, uncertain.id).status == "uncertain"

    assert {:ok, queued} =
             Conversations.send_federation_message(
               plain.id,
               %{
                 version: consented.version,
                 body: "Synthetic queued send with no native attempt",
                 idempotency_key: Ecto.UUID.generate()
               },
               peer_subject
             )

    assert {:ok, credential} =
             ServiceAccounts.create_view(
               %{
                 name: "Composed SCIM directory",
                 scopes: ["scim:read", "scim:write"],
                 reason: "Verify private and Federation withdrawal in the same transaction"
               },
               c.subject
             )

    assert {:ok, service} = ServiceAccounts.authenticate(credential.credential)

    binding =
      Repo.insert!(%CommsCore.Accounts.ScimResource{
        tenant_id: c.account.tenant.id,
        user_id: peer.id,
        kind: "User",
        external_id: "composed-scim:" <> peer.id,
        display_name: peer.display_name
      })

    assert {:ok, resource} = Accounts.scim_get("User", binding.id, service)
    effects_before_suspension = Process.get(:scim_federation_effects)

    assert {:ok, suspended} =
             Accounts.scim_patch(
               "User",
               resource.id,
               %{
                 "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
                 "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
               },
               resource.meta.version,
               service
             )

    assert peer_subject.session_id in suspended.revoked_session_ids
    assert Repo.get!(User, peer.id).status == :suspended
    assert Repo.get!(Session, peer_subject.session_id).revoked_at
    assert Repo.get!(MatrixClientSession, native.id).state == :cleanup_pending
    fenced_private = Repo.get!(PrivateRoom, original_private.id)
    assert fenced_private.state == :rekey_pending
    assert fenced_private.generation == original_private.generation + 1
    assert fenced_private.membership_epoch == original_private.membership_epoch + 1
    removed_principal = original_private.matrix_members[peer.id]["matrix_user_id"]
    assert removed_principal in fenced_private.pending_removed_matrix_user_ids
    assert Repo.get_by!(Membership, conversation_id: private.id, user_id: peer.id).left_at
    participant = Repo.get_by!(Participant, room_id: bridge.id, user_id: peer.id)
    assert participant.consent_status == "withdrawn" and participant.withdrawn_at

    for id <- [uncertain.id, queued.id] do
      cancelled = Repo.get!(Command, id)
      assert cancelled.status == "cancelled" and is_nil(cancelled.payload_box)
      assert :ok = worker.perform(%Oban.Job{args: %{"command_id" => id}})
    end

    # The SCIM transaction and cancelled workers never make another native call.
    assert Process.get(:scim_federation_effects) == effects_before_suspension
    refute_received {:scim_private_ban, _}
    refute_received {:scim_unexpected_private_send, _}
    assert {:error, :forbidden} = Accounts.matrix_client_session(peer_subject)
    assert {:error, :forbidden} = Conversations.private_room(private.id, peer_subject)
    assert {:error, :forbidden} = Conversations.federation_room(plain.id, peer_subject)

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(c.account.tenant.id, :user, peer.id)

    assert {:ok, true} =
             Conversations.private_room_erasure_pending?(c.account.tenant.id, :user, peer.id)

    assert Accounts.matrix_identity_erasure_pending?(c.account.tenant.id, peer.id)

    assert {:ok, _} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"active" => true},
               suspended.meta.version,
               service
             )

    fresh =
      CommsCore.TrustGovernanceTestSupport.authenticated_subject(
        c.account,
        peer,
        "Re-enabled bridge peer"
      )

    assert {:ok, _} = Accounts.matrix_client_session(fresh)
    assert Repo.get!(User, peer.id).status == :active
    assert Repo.get!(MatrixClientSession, native.id).state == :cleanup_pending
    assert {:error, :forbidden} = Accounts.matrix_client_session(peer_subject)
    assert {:error, :forbidden} = Conversations.private_room(private.id, fresh)
    assert {:ok, withdrawn} = Conversations.federation_room(plain.id, fresh)
    assert withdrawn.consent == "withdrawn"

    assert {:error, :federation_consent_required} =
             Conversations.send_federation_message(
               plain.id,
               %{
                 version: withdrawn.version,
                 body: "Re-enabled identity cannot revive consent",
                 idempotency_key: Ecto.UUID.generate()
               },
               fresh
             )

    assert {:error, :withdrawn_consent_requires_new_room} =
             Conversations.federation_consent(
               plain.id,
               %{version: withdrawn.version, accept: true, plaintext_disclosure_accepted: true},
               fresh
             )

    assert {:error, :private_room_rekey_pending} =
             Messaging.send_private_event(
               private.id,
               %{
                 membership_epoch: fenced_private.membership_epoch,
                 generation: fenced_private.generation,
                 transaction_id: "scim-fenced-private-send",
                 content: %{
                   "algorithm" => "m.megolm.v1.aes-sha2",
                   "session_id" => Base.encode64(:binary.copy(<<1>>, 32), padding: false),
                   "ciphertext" => Base.encode64(:binary.copy(<<1>>, 48), padding: false)
                 }
               },
               c.subject
             )

    # Missing native ban/transaction observations retain their own obligations.
    private_worker = RuntimePorts.job_worker!(:private_room_purge_reconciler)

    assert {:ok, %{provider_purged: 0}} =
             Conversations.reconcile_private_room_purges(private_worker)

    assert_received {:scim_private_ban, ^removed_principal}
    assert Repo.get!(PrivateRoom, original_private.id) == fenced_private

    recoveries =
      Repo.all(
        from(command in Command,
          where: command.room_id == ^bridge.id and command.kind == "recover_send"
        )
      )

    assert length(recoveries) == 2

    by_source =
      Map.new(recoveries, fn command ->
        assert {:ok, payload} =
                 SecretBox.open(command.tenant_id, command.id, "command", command.payload_box)

        {payload["source_transaction_id"], command}
      end)

    assert Enum.sort(Map.keys(by_source)) == Enum.sort([uncertain.id, queued.id])
    recovery = Map.fetch!(by_source, uncertain.id)

    for _ <- 1..2 do
      assert {:error, :federation_send_outcome_unconfirmed} =
               worker.perform(%Oban.Job{args: %{"command_id" => recovery.id}})

      assert :ok = worker.perform(%Oban.Job{args: %{"command_id" => uncertain.id}})
    end

    leave = Repo.get_by!(Command, room_id: bridge.id, kind: "leave")
    assert :ok = worker.perform(%Oban.Job{args: %{"command_id" => leave.id}})
    assert Repo.get!(Command, recovery.id).status == "uncertain"
    assert Repo.get!(Room, bridge.id).remote_cleanup_state == "remote_unconfirmed"

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(c.account.tenant.id, :user, peer.id)

    assert {:ok, true} =
             Conversations.private_room_erasure_pending?(c.account.tenant.id, :user, peer.id)

    assert Accounts.matrix_identity_erasure_pending?(c.account.tenant.id, peer.id)
    refute_received {:scim_unexpected_private_send, _}

    effects = Process.get(:scim_federation_effects)
    assert Enum.count(effects, &(&1.operation == :create)) == 1

    assert Enum.count(effects, &(&1.operation == :send and &1.transaction_id == uncertain.id)) ==
             1

    refute Enum.any?(effects, &(&1.operation == :send and &1.transaction_id == queued.id))
    observations = Enum.filter(effects, &(&1.operation == :recover_event))
    assert length(observations) == 2

    assert Enum.all?(
             observations,
             &(&1.source_transaction_id == uncertain.id and &1.effect_mode == :recovery_only)
           )

    # Withdrawal of one participant preserves the other owner's authority/lineage.
    assert Repo.get_by!(Participant, room_id: bridge.id, user_id: c.account.user.id) ==
             owner_participant

    assert Repo.get!(MatrixClientSession, owner_native.id) == owner_native
    refute Repo.get!(Session, c.subject.session_id).revoked_at
    assert Repo.get!(Room, bridge.id).status == "active"

    lineage = [:provider_issuer, :provider_server_name, :provider_bridge_user, :alias_localpart]
    assert Map.take(Repo.get!(Room, bridge.id), lineage) == Map.take(original_bridge, lineage)

    private_lineage = [
      :historical_user_ids,
      :matrix_members,
      :provider_issuer,
      :server_name,
      :control_matrix_user_id,
      :room_alias
    ]

    assert Map.take(fenced_private, private_lineage) ==
             Map.take(original_private, private_lineage)

    assert {:ok, owner_bridge} = Conversations.federation_room(plain.id, c.subject)
    assert owner_bridge.consent == "accepted"
  end

  defp create_bridge(c, id \\ nil),
    do:
      Conversations.create_federation_room(
        id || c.account.conversation.id,
        %{
          domain: "remote.example.org",
          plaintext_disclosure_accepted: true
        },
        c.subject
      )
end
