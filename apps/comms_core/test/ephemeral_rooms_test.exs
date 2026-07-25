defmodule CommsCore.Conversations.EphemeralRoomsTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  @token_bytes 32

  alias CommsCore.{
    Accounts,
    Attachments,
    AudioCalls,
    Conversations,
    Messaging,
    Repo,
    RuntimePorts
  }

  alias CommsCore.Accounts.Session

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralJoinReceipt,
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsTestSupport.Fixtures

  setup do
    enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    on_exit(fn ->
      restore_env(:instant_rooms_enabled, enabled)
      restore_env(:instant_room_tenant_slug, slug)
    end)

    :ok
  end

  test "guest creation persists digest-only authority and previews the room" do
    account = Fixtures.account_fixture()
    idempotency_key = secret()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, idempotency_key),
               :guest
             )

    assert byte_size(created.join_token) == 43
    assert created.room.status == :active
    assert created.room.owner_kind == :guest
    assert created.authentication.user.account_type == :guest
    assert created.membership.role == :owner
    refute created.replayed

    room = Repo.get!(EphemeralRoom, created.room.id)
    link = Repo.get!(GuestLink, room.guest_link_id)
    admission = Repo.get!(GuestAdmission, created.admission.id)

    assert link.purpose == :ephemeral_room
    assert link.token_digest == created.join_token |> decode_secret!() |> sha256()
    assert byte_size(room.replay_ciphertext) > 0
    refute room.replay_ciphertext == created.join_token
    refute :erlang.term_to_binary(room) =~ created.join_token
    assert admission.session_id == created.authentication.session_id

    assert {:ok, preview} =
             Conversations.preview_ephemeral_room(created.join_token)

    assert preview.room_id == room.id
    assert preview.room_title == "Instant room"
    assert preview.status == :active

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(secret())
  end

  test "exact create replay returns the identical token and rebinds a usable guest session" do
    account = Fixtures.account_fixture()
    idempotency_key = secret()
    attrs = guest_create_attrs(account.tenant.id, idempotency_key)

    assert {:ok, first} = Conversations.create_ephemeral_room(attrs, :guest)
    old_session_id = first.authentication.session_id

    assert {:ok, replay} = Conversations.create_ephemeral_room(attrs, :guest)
    assert replay.replayed
    assert replay.room.id == first.room.id
    assert replay.join_token == first.join_token
    assert replay.authentication.user.id == first.authentication.user.id
    refute replay.authentication.session_id == old_session_id
    assert replay.admission.id == first.admission.id
    assert replay.membership.id == first.membership.id

    room = Repo.get!(EphemeralRoom, first.room.id)
    admission = Repo.get!(GuestAdmission, first.admission.id)

    assert room.creator_session_id == replay.authentication.session_id
    assert admission.session_id == replay.authentication.session_id
    assert %Session{revoked_at: %DateTime{}} = Repo.get!(Session, old_session_id)

    assert {:ok, _context} =
             Accounts.guest_access_context(replay.authentication.session_id, "replay-test")

    assert {:error, :idempotency_conflict} =
             Conversations.create_ephemeral_room(
               Map.put(attrs, :title, "Different request"),
               :guest
             )
  end

  test "guest join is idempotent and preserves one identity, membership, and admission" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    attrs = guest_join_attrs(secret())

    assert {:ok, first} =
             Conversations.join_ephemeral_room(created.join_token, attrs, :guest)

    assert {:ok, replay} =
             Conversations.join_ephemeral_room(created.join_token, attrs, :guest)

    assert first.membership_changed
    assert replay.replayed
    refute replay.membership_changed
    assert replay.authentication.user.id == first.authentication.user.id
    assert replay.membership.id == first.membership.id
    assert replay.admission.id == first.admission.id
    refute replay.authentication.session_id == first.authentication.session_id

    assert Repo.aggregate(
             from(admission in GuestAdmission,
               where:
                 admission.guest_link_id == ^created.admission.guest_link_id and
                   not is_nil(admission.join_idempotency_digest)
             ),
             :count
           ) == 1
  end

  test "human creation requires workspace scope and same-tenant human join is membership-idempotent" do
    owner = Fixtures.account_fixture()
    configure_public_tenant!(owner.tenant.id)
    subject = Fixtures.subject(owner)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Human room"},
               subject
             )

    assert created.room.owner_kind == :registered
    assert created.authentication == nil
    assert created.membership.role == :owner

    other = Fixtures.user_fixture(owner)

    {:ok, other_session} =
      Accounts.authenticate_view(
        owner.tenant.slug,
        other.user.email,
        password_for(other.user.email),
        %{name: "Other browser", platform: "test"}
      )

    other_subject = authenticated_subject(other_session)
    join_attrs = %{idempotency_key: secret()}

    assert {:ok, joined} =
             Conversations.join_ephemeral_room(
               created.join_token,
               join_attrs,
               other_subject
             )

    assert {:ok, replayed} =
             Conversations.join_ephemeral_room(
               created.join_token,
               join_attrs,
               other_subject
             )

    refute joined.replayed
    assert joined.membership_changed
    assert replayed.replayed
    refute replayed.membership_changed
    assert replayed.membership.id == joined.membership.id

    assert {:ok, active_member_join} =
             Conversations.join_ephemeral_room(
               created.join_token,
               %{idempotency_key: secret()},
               other_subject
             )

    refute active_member_join.replayed
    refute active_member_join.membership_changed
    assert active_member_join.membership.id == joined.membership.id
  end

  test "same-tenant conversation-only humans reuse their identity for instant-room create and join" do
    account = Fixtures.account_fixture()

    assert {:ok, original_guest} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: "scoped-identity-#{System.unique_integer([:positive])}@example.test",
                 password: "correct-conversation-scoped-password-123",
                 display_name: "Scoped identity",
                 device: %{name: "Scoped browser", platform: "test"}
               },
               guest_subject(original_guest)
             )

    scoped_subject = authenticated_subject(converted.authentication)
    scoped_user_id = converted.authentication.user.id

    assert {:ok, scoped_room} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Scoped owner room"},
               scoped_subject
             )

    assert scoped_room.room.owner_kind == :registered
    assert scoped_room.room.owner_user_id == scoped_user_id
    assert scoped_room.membership.user_id == scoped_user_id
    assert scoped_room.authentication == nil
    assert scoped_room.admission == nil

    workspace_subject = Fixtures.subject(account)

    assert {:ok, target_room} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Scoped join target"},
               workspace_subject
             )

    join_attrs = %{idempotency_key: secret()}

    assert {:ok, joined} =
             Conversations.join_ephemeral_room(
               target_room.join_token,
               join_attrs,
               scoped_subject
             )

    assert joined.membership.user_id == scoped_user_id
    assert joined.authentication == nil
    assert joined.admission == nil

    assert {:ok, replayed} =
             Conversations.join_ephemeral_room(
               target_room.join_token,
               join_attrs,
               scoped_subject
             )

    assert replayed.replayed
    assert replayed.membership.id == joined.membership.id

    departed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(membership in Membership, where: membership.id == ^joined.membership.id),
      set: [left_at: departed_at]
    )

    assert {:ok, rejoined} =
             Conversations.join_ephemeral_room(
               target_room.join_token,
               %{idempotency_key: secret()},
               scoped_subject
             )

    assert rejoined.membership.id == joined.membership.id
    assert rejoined.membership_changed
    assert Repo.get!(Membership, joined.membership.id).left_at == nil
    assert {:error, :forbidden} = Conversations.authorize_create(scoped_subject)

    assert {:error, :forbidden} =
             Conversations.create(%{kind: :group, title: "Workspace-only"}, scoped_subject)
  end

  test "presence leases reactivate, reconcile with generation fencing, and expire atomically" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    subject = guest_subject(created)
    connection_id = secret()

    presence_attrs =
      subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, connection_id)

    assert {:ok, opened} = Conversations.open_ephemeral_presence(presence_attrs)
    assert opened.room.status == :active
    assert %EphemeralPresenceLease{} = Repo.get!(EphemeralPresenceLease, opened.lease.id)

    assert {:ok, heartbeat} = Conversations.heartbeat_ephemeral_presence(presence_attrs)
    assert heartbeat.lease.id == opened.lease.id

    assert {:ok, closed} = Conversations.close_ephemeral_presence(presence_attrs)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, :active} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               closed.generation,
               reconciler
             )

    old = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [last_presence_at: old, inserted_at: old]
    )

    assert {:ok, {:idle, expires_at, idle_generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               closed.generation,
               reconciler
             )

    assert {:ok, :stale_generation} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               closed.generation,
               reconciler
             )

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    expired_idle_since = DateTime.add(expired_at, -120, :second)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [idle_since: expired_idle_since, expires_at: expired_at]
    )

    lifecycle = RuntimePorts.job_worker!(:ephemeral_room_lifecycle)

    assert {:ok, :expired} =
             Conversations.expire_ephemeral_room(
               created.room.id,
               idle_generation,
               lifecycle
             )

    assert %EphemeralRoom{status: :expired, expired_at: %DateTime{}} =
             Repo.get!(EphemeralRoom, created.room.id)

    assert %Conversation{archived_at: %DateTime{}} =
             Repo.get!(Conversation, created.conversation.id)

    assert %GuestLink{revoked_at: %DateTime{}} =
             Repo.get!(GuestLink, created.admission.guest_link_id)

    assert %Membership{left_at: %DateTime{}} =
             Repo.get!(Membership, created.membership.id)

    assert DateTime.compare(expires_at, expired_at) == :gt
  end

  test "multiple connections keep the room active until the final lease closes" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    subject = guest_subject(created)

    first =
      subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    second =
      subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:ok, _} = Conversations.open_ephemeral_presence(first)
    assert {:ok, _} = Conversations.open_ephemeral_presence(second)
    assert {:ok, first_close} = Conversations.close_ephemeral_presence(first)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, :active} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               first_close.generation,
               reconciler
             )

    assert {:ok, final_close} = Conversations.close_ephemeral_presence(second)
    force_past_reconnect_grace(created.room.id)

    assert {:ok, {:idle, _expires_at, _generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               final_close.generation,
               reconciler
             )
  end

  test "registered creator rejoin cancels idle expiry and fences the old generation" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)
    subject = Fixtures.subject(account)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Rejoin room"},
               subject
             )

    force_past_reconnect_grace(created.room.id)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, {:idle, _expires_at, idle_generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               room_generation(created.room.id),
               reconciler
             )

    assert {:ok, rejoined} =
             Conversations.join_ephemeral_room(
               created.join_token,
               %{idempotency_key: secret()},
               subject
             )

    assert rejoined.room.status == :active
    assert rejoined.room.expires_at == nil
    assert room_generation(rejoined.room.id) > idle_generation

    assert {:ok, %{scanned: 1, reconciled: 0}} =
             Conversations.reconcile_ephemeral_rooms(reconciler)

    assert %EphemeralRoom{status: :active, expires_at: nil, last_presence_at: %DateTime{}} =
             Repo.get!(EphemeralRoom, rejoined.room.id)

    lifecycle = RuntimePorts.job_worker!(:ephemeral_room_lifecycle)

    assert {:ok, :stale_generation} =
             Conversations.expire_ephemeral_room(
               created.room.id,
               idle_generation,
               lifecycle
             )
  end

  test "guest and registered creators receive their configured idle TTLs" do
    account = Fixtures.account_fixture()

    assert {:ok, guest_room} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, registered_room} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Registered TTL"},
               Fixtures.subject(account)
             )

    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    for room <- [guest_room.room, registered_room.room] do
      force_past_reconnect_grace(room.id)
    end

    assert {:ok, {:idle, guest_expiry, _}} =
             Conversations.reconcile_ephemeral_room(
               guest_room.room.id,
               room_generation(guest_room.room.id),
               reconciler
             )

    assert {:ok, {:idle, registered_expiry, _}} =
             Conversations.reconcile_ephemeral_room(
               registered_room.room.id,
               room_generation(registered_room.room.id),
               reconciler
             )

    guest = Repo.get!(EphemeralRoom, guest_room.room.id)
    registered = Repo.get!(EphemeralRoom, registered_room.room.id)

    assert DateTime.diff(guest_expiry, guest.idle_since, :second) ==
             Application.fetch_env!(:comms_core, :instant_room_guest_idle_ttl_seconds)

    assert DateTime.diff(registered_expiry, registered.idle_since, :second) ==
             Application.fetch_env!(:comms_core, :instant_room_registered_idle_ttl_seconds)
  end

  test "idle TTL is anchored to the authoritative final disconnect despite delayed reconciliation" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    presence_attrs =
      created
      |> guest_subject()
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:ok, opened} = Conversations.open_ephemeral_presence(presence_attrs)
    assert {:ok, closed} = Conversations.close_ephemeral_presence(presence_attrs)

    disconnect_at =
      DateTime.utc_now()
      |> DateTime.add(-10, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(lease in EphemeralPresenceLease, where: lease.id == ^opened.lease.id),
      set: [
        opened_at: DateTime.add(disconnect_at, -1, :second),
        last_seen_at: disconnect_at,
        expires_at: DateTime.add(disconnect_at, 1, :second),
        closed_at: disconnect_at
      ]
    )

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [last_presence_at: disconnect_at]
    )

    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, {:idle, expires_at, _generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               closed.generation,
               reconciler
             )

    idle = Repo.get!(EphemeralRoom, created.room.id)
    assert idle.idle_since == disconnect_at

    assert expires_at ==
             DateTime.add(
               disconnect_at,
               Application.fetch_env!(:comms_core, :instant_room_guest_idle_ttl_seconds),
               :second
             )
  end

  test "overdue idle rooms deny message, call, and attachment access before expiry work runs" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)
    subject = Fixtures.subject(account)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Authorization deadline"},
               subject
             )

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    future_expiry = DateTime.add(timestamp, 60, :second)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [status: :idle, idle_since: timestamp, expires_at: future_expiry]
    )

    assert :ok = Conversations.authorize_read(created.conversation.id, subject)
    assert :ok = Conversations.authorize_send_message(created.conversation.id, subject)

    assert {:ok, _membership} =
             Conversations.call_membership(
               account.tenant.id,
               created.conversation.id,
               account.user.id
             )

    assert {:ok, nil} = AudioCalls.get_active(created.conversation.id, subject)

    assert {:ok, %{files: []}} =
             Attachments.list_files(subject, %{conversation_id: created.conversation.id})

    past_expiry = DateTime.add(timestamp, -1, :second)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [idle_since: DateTime.add(timestamp, -2, :second), expires_at: past_expiry]
    )

    for authorize <- [
          &Conversations.authorize_read/2,
          &Conversations.authorize_send_message/2,
          &Conversations.authorize_mark_read/2,
          &Conversations.authorize_react_message/2,
          &Conversations.authorize_upload_attachment/2
        ] do
      assert {:error, :forbidden} = authorize.(created.conversation.id, subject)
    end

    assert {:error, :forbidden} =
             Conversations.call_membership(
               account.tenant.id,
               created.conversation.id,
               account.user.id
             )

    assert {:error, :forbidden} = AudioCalls.get_active(created.conversation.id, subject)

    assert {:error, :forbidden} =
             Attachments.list_files(subject, %{conversation_id: created.conversation.id})

    assert {:error, :forbidden} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: created.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "overdue-room-message",
                 body: "This must not be persisted"
               },
               subject
             )

    assert [] =
             Conversations.list_for_user(subject)
             |> Enum.filter(&(&1.conversation.id == created.conversation.id))
  end

  test "stale active rooms fail closed after reconnect grace and recover through a live lease" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)
    subject = Fixtures.subject(account)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Stale active room"},
               subject
             )

    assert :ok = Conversations.authorize_send_message(created.conversation.id, subject)

    beyond_grace =
      DateTime.utc_now()
      |> DateTime.add(-10, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [inserted_at: beyond_grace, updated_at: beyond_grace]
    )

    assert {:error, :forbidden} =
             Conversations.authorize_send_message(created.conversation.id, subject)

    presence_attrs =
      subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:ok, _opened} = Conversations.open_ephemeral_presence(presence_attrs)
    assert :ok = Conversations.authorize_send_message(created.conversation.id, subject)
  end

  test "global reconciliation recreates missing idle expiry work" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    force_past_reconnect_grace(created.room.id)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, {:idle, expires_at, generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               room_generation(created.room.id),
               reconciler
             )

    lifecycle_worker = RuntimePorts.job_worker_name!(:ephemeral_room_lifecycle)

    lifecycle_jobs =
      from(job in Oban.Job,
        where:
          job.worker == ^lifecycle_worker and
            fragment("?->>'room_id'", job.args) == ^created.room.id and
            fragment("(?->>'generation')::bigint", job.args) == ^generation
      )

    assert {1, _} = Repo.delete_all(lifecycle_jobs)
    refute Repo.exists?(lifecycle_jobs)

    assert {:ok, %{scanned: 1, reconciled: 1}} =
             Conversations.reconcile_ephemeral_rooms(reconciler)

    assert %Oban.Job{state: "scheduled", scheduled_at: scheduled_at} = Repo.one!(lifecycle_jobs)
    assert DateTime.compare(scheduled_at, expires_at) == :eq
  end

  test "participant limit rejects excess admissions without consuming the share token" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [participant_limit: 2]
    )

    assert {:ok, _first_guest} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert {:error, :conversation_member_quota_exceeded} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert Repo.get!(GuestLink, created.admission.guest_link_id).use_count == 0
  end

  test "malformed, tampered, and expired tokens are indistinguishable" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    for token <- ["not-a-token", secret()] do
      assert {:error, :ephemeral_room_unavailable} =
               Conversations.preview_ephemeral_room(token)

      assert {:error, :ephemeral_room_unavailable} =
               Conversations.join_ephemeral_room(
                 token,
                 guest_join_attrs(secret()),
                 :guest
               )
    end

    old = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:microsecond)
    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(link in GuestLink, where: link.id == ^created.admission.guest_link_id),
      set: [inserted_at: old, expires_at: expired]
    )

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(created.join_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )
  end

  test "self-service conversion preserves identity and upgrades only the guest owner" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    guest_subject = guest_subject(created)

    tab_attrs =
      Enum.map(1..5, fn _index ->
        attrs =
          guest_subject
          |> Map.put(:conversation_id, created.conversation.id)
          |> Map.put(:connection_id, secret())

        assert {:ok, _opened} = Conversations.open_ephemeral_presence(attrs)
        attrs
      end)

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: "instant-owner@example.test",
                 password: "correct-horse-battery-instant-owner",
                 display_name: "Instant owner",
                 device: %{name: "Converted browser", platform: "test"}
               },
               guest_subject
             )

    assert converted.authentication.user.id == created.authentication.user.id
    assert converted.authentication.user.account_type == :human
    assert converted.authentication.user.access_scope == :conversation_only
    assert converted.ephemeral_owner_upgraded

    assert %EphemeralRoom{owner_kind: :registered, creator_session_id: new_session_id} =
             Repo.get!(EphemeralRoom, created.room.id)

    assert new_session_id == converted.authentication.session_id
    converted_subject = authenticated_subject(converted.authentication)

    handed_off_leases =
      Repo.all(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^created.room.id and
              lease.user_id == ^converted.authentication.user.id
        )
      )

    assert length(handed_off_leases) == 5
    assert Enum.all?(handed_off_leases, &(&1.session_id == new_session_id))
    assert Enum.all?(handed_off_leases, &match?(%DateTime{}, &1.closed_at))

    Enum.each(tab_attrs, fn attrs ->
      attrs =
        converted_subject
        |> Map.put(:conversation_id, attrs.conversation_id)
        |> Map.put(:connection_id, attrs.connection_id)

      assert {:ok, _reopened} = Conversations.open_ephemeral_presence(attrs)
    end)

    assert {:error, :forbidden} = Conversations.authorize_create(converted_subject)

    assert {:error, :forbidden} =
             Conversations.create(%{kind: :group, title: "Forbidden"}, converted_subject)
  end

  test "idle guest-owner conversion extends the room, link, and active admissions to registered TTL" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, joined_guest} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    force_past_reconnect_grace(created.room.id)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, {:idle, original_guest_deadline, _generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               room_generation(created.room.id),
               reconciler
             )

    assert Repo.get!(GuestLink, created.admission.guest_link_id).expires_at ==
             original_guest_deadline

    assert Repo.get!(GuestAdmission, joined_guest.admission.id).expires_at ==
             original_guest_deadline

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: "idle-owner-#{System.unique_integer([:positive])}@example.test",
                 password: "correct-idle-owner-password-123",
                 display_name: "Idle registered owner",
                 device: %{name: "Converted browser", platform: "test"}
               },
               guest_subject(created)
             )

    upgraded = Repo.get!(EphemeralRoom, created.room.id)

    registered_ttl =
      Application.fetch_env!(:comms_core, :instant_room_registered_idle_ttl_seconds)

    assert upgraded.owner_kind == :registered
    assert upgraded.status == :idle
    assert upgraded.expires_at == DateTime.add(upgraded.idle_since, registered_ttl, :second)
    assert DateTime.compare(upgraded.expires_at, original_guest_deadline) == :gt
    assert upgraded.authority_expires_at == upgraded.expires_at
    assert Repo.get!(GuestLink, upgraded.guest_link_id).expires_at == upgraded.expires_at
    assert Repo.get!(GuestAdmission, joined_guest.admission.id).expires_at == upgraded.expires_at

    converted_subject = authenticated_subject(converted.authentication)

    assert {:ok, rejoined} =
             Conversations.join_ephemeral_room(
               created.join_token,
               %{idempotency_key: secret()},
               converted_subject
             )

    assert rejoined.membership.user_id == converted.authentication.user.id
    assert rejoined.room.status == :active
  end

  test "composite lease constraint rejects a room and conversation mismatch" do
    account = Fixtures.account_fixture()

    assert {:ok, first} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, second} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Other room"},
               Fixtures.subject(account)
             )

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    invalid_changeset =
      EphemeralPresenceLease.changeset(%EphemeralPresenceLease{}, %{
        tenant_id: account.tenant.id,
        ephemeral_room_id: first.room.id,
        conversation_id: second.conversation.id,
        user_id: first.authentication.user.id,
        session_id: first.authentication.session_id,
        connection_digest: sha256(decode_secret!(secret())),
        opened_at: timestamp,
        last_seen_at: timestamp,
        expires_at: DateTime.add(timestamp, 90, :second)
      })

    assert_raise Ecto.ConstraintError,
                 ~r/conversation_ephemeral_presence_leases_tenant_room_fk/,
                 fn -> Repo.insert!(invalid_changeset) end
  end

  test "configured public tenant is authoritative for guest and registered creation" do
    public = Fixtures.account_fixture()
    foreign = Fixtures.account_fixture()
    configure_public_tenant!(public.tenant.id)

    assert {:ok, guest_room} =
             Conversations.create_ephemeral_room(
               %{
                 tenant_id: foreign.tenant.id,
                 idempotency_key: secret(),
                 display_name: "Public guest",
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )

    assert guest_room.authentication.tenant.id == public.tenant.id

    assert {:error, :forbidden} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Cross tenant"},
               Fixtures.subject(foreign)
             )
  end

  test "guest and human join receipts reject conflicts and expire after ten minutes" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    guest_key = secret()
    guest_attrs = guest_join_attrs(guest_key)

    assert {:ok, guest_join} =
             Conversations.join_ephemeral_room(created.join_token, guest_attrs, :guest)

    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(admission in GuestAdmission, where: admission.id == ^guest_join.admission.id),
      set: [admitted_at: DateTime.add(past, -600, :second), idempotency_expires_at: past]
    )

    assert {:error, :idempotency_replay_expired} =
             Conversations.join_ephemeral_room(created.join_token, guest_attrs, :guest)

    first_human = authenticated_human_fixture(account)
    second_human = authenticated_human_fixture(account)
    human_key = secret()
    human_attrs = %{idempotency_key: human_key}

    assert {:ok, first_join} =
             Conversations.join_ephemeral_room(
               created.join_token,
               human_attrs,
               first_human
             )

    assert {:error, :idempotency_conflict} =
             Conversations.join_ephemeral_room(
               created.join_token,
               human_attrs,
               second_human
             )

    receipt =
      Repo.get_by!(EphemeralJoinReceipt,
        ephemeral_room_id: created.room.id,
        membership_id: first_join.membership.id
      )

    Repo.update_all(
      from(value in EphemeralJoinReceipt, where: value.id == ^receipt.id),
      set: [inserted_at: DateTime.add(past, -600, :second), expires_at: past]
    )

    assert {:error, :idempotency_replay_expired} =
             Conversations.join_ephemeral_room(
               created.join_token,
               human_attrs,
               first_human
             )
  end

  test "active lease cap allows five tabs and ignores an expired lease" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    subject = guest_subject(created)

    opened =
      Enum.map(1..5, fn _index ->
        attrs =
          subject
          |> Map.put(:conversation_id, created.conversation.id)
          |> Map.put(:connection_id, secret())

        assert {:ok, lease} = Conversations.open_ephemeral_presence(attrs)
        {attrs, lease}
      end)

    sixth =
      subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:error, :ephemeral_presence_limit_exceeded} =
             Conversations.open_ephemeral_presence(sixth)

    {_attrs, first} = hd(opened)

    old_seen =
      DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

    old_expiry = DateTime.add(old_seen, 1, :second)

    Repo.update_all(
      from(lease in EphemeralPresenceLease, where: lease.id == ^first.lease.id),
      set: [
        opened_at: DateTime.add(old_seen, -1, :second),
        last_seen_at: old_seen,
        expires_at: old_expiry
      ]
    )

    assert {:ok, _sixth_opened} = Conversations.open_ephemeral_presence(sixth)
  end

  test "an overdue idle room cannot be reactivated before delayed expiry work runs" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)
    subject = Fixtures.subject(account)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Overdue room"},
               subject
             )

    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [status: :idle, idle_since: DateTime.add(past, -60, :second), expires_at: past]
    )

    attrs =
      subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.open_ephemeral_presence(attrs)

    assert Repo.get!(EphemeralRoom, created.room.id).status == :idle
  end

  test "explicit guest logout terminalizes room admission and presence without poisoning refresh" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, joined} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    joined_subject = guest_subject(joined)

    presence_attrs =
      joined_subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:ok, opened} = Conversations.open_ephemeral_presence(presence_attrs)
    assert :ok = Conversations.logout_guest_session(joined_subject)

    assert %GuestAdmission{revoked_at: %DateTime{}} =
             Repo.get!(GuestAdmission, joined.admission.id)

    assert %Membership{left_at: %DateTime{}} =
             Repo.get!(Membership, joined.membership.id)

    assert %Session{revoked_at: %DateTime{}} =
             Repo.get!(Session, joined.authentication.session_id)

    assert %EphemeralPresenceLease{
             session_id: session_id,
             closed_at: %DateTime{}
           } = Repo.get!(EphemeralPresenceLease, opened.lease.id)

    assert session_id == joined.authentication.session_id

    refresh_due =
      DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [authority_expires_at: refresh_due]
    )

    guest_link_id = Repo.get!(EphemeralRoom, created.room.id).guest_link_id

    Repo.update_all(
      from(link in GuestLink, where: link.id == ^guest_link_id),
      set: [expires_at: refresh_due]
    )

    Repo.update_all(
      from(admission in GuestAdmission, where: admission.id == ^created.admission.id),
      set: [expires_at: refresh_due]
    )

    host_attrs =
      created
      |> guest_subject()
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:ok, _host_presence} = Conversations.open_ephemeral_presence(host_attrs)

    refreshed = Repo.get!(EphemeralRoom, created.room.id)
    assert DateTime.compare(refreshed.authority_expires_at, refresh_due) == :gt
  end

  test "feature disable fails preview, join, and self-service conversion closed" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    guest_subject = guest_subject(created)
    Application.put_env(:comms_core, :instant_rooms_enabled, false)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(created.join_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert {:error, :instant_rooms_unavailable} =
             Conversations.convert_guest_account(
               %{
                 email: "disabled@example.test",
                 password: "correct-horse-battery-disabled"
               },
               guest_subject
             )
  end

  test "guest display names accept 120 characters and reject 121" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{
                 idempotency_key: secret(),
                 display_name: String.duplicate("a", 120),
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )

    assert String.length(created.authentication.user.display_name) == 120

    assert {:error, :invalid_guest_display_name} =
             Conversations.create_ephemeral_room(
               %{
                 idempotency_key: secret(),
                 display_name: String.duplicate("b", 121),
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )
  end

  test "noncanonical Base64URL token and idempotency encodings fail closed" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    noncanonical_token = noncanonical_encoding(created.join_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(noncanonical_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.join_ephemeral_room(
               noncanonical_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert {:error, :invalid_idempotency_key} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, noncanonical_encoding(secret())),
               :guest
             )
  end

  test "bounded reconciliation cryptographically erases expired replay capsules while disabled" do
    account = Fixtures.account_fixture()
    idempotency_key = secret()
    attrs = guest_create_attrs(account.tenant.id, idempotency_key)

    assert {:ok, created} = Conversations.create_ephemeral_room(attrs, :guest)
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
    inserted_at = DateTime.add(past, -600, :second)
    last_presence_at = DateTime.add(past, -9, :second)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [
        inserted_at: inserted_at,
        idempotency_expires_at: past,
        last_presence_at: last_presence_at
      ]
    )

    Application.put_env(:comms_core, :instant_rooms_enabled, false)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, %{scanned: 1, reconciled: 1, scrubbed: 1}} =
             Conversations.reconcile_ephemeral_rooms(reconciler)

    scrubbed = Repo.get!(EphemeralRoom, created.room.id)
    assert scrubbed.status == :idle
    assert scrubbed.replay_ciphertext == nil
    assert scrubbed.replay_nonce == nil
    assert scrubbed.replay_tag == nil
    assert scrubbed.replay_key_id == nil
    assert %DateTime{} = scrubbed.replay_erased_at

    assert DateTime.compare(scrubbed.replay_erased_at, scrubbed.idempotency_expires_at) in [
             :eq,
             :gt
           ]

    assert byte_size(scrubbed.idempotency_digest) == 32
    assert byte_size(scrubbed.request_fingerprint) == 32

    partial_changeset =
      EphemeralRoom.changeset(scrubbed, %{
        replay_ciphertext: <<1>>
      })

    refute partial_changeset.valid?

    assert {"must be complete encrypted replay material or an expired erased capsule", _} =
             Keyword.fetch!(partial_changeset.errors, :replay_ciphertext)

    creation_changeset = EphemeralRoom.changeset(%EphemeralRoom{}, %{})
    refute creation_changeset.valid?

    assert {"must be complete encrypted replay material or an expired erased capsule", _} =
             Keyword.fetch!(creation_changeset.errors, :replay_ciphertext)

    Application.put_env(:comms_core, :instant_rooms_enabled, true)

    assert {:error, :idempotency_replay_expired} =
             Conversations.create_ephemeral_room(attrs, :guest)

    force_past_reconnect_grace(created.room.id)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, {:idle, _expires_at, _generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               room_generation(created.room.id),
               reconciler
             )
  end

  test "fresh schema permits only complete or erased replay capsules" do
    nullable_columns =
      Repo.query!(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'conversation_ephemeral_rooms'
          AND column_name IN (
            'replay_ciphertext',
            'replay_nonce',
            'replay_tag',
            'replay_key_id',
            'replay_erased_at'
          )
          AND is_nullable = 'YES'
        ORDER BY column_name
        """,
        []
      )
      |> Map.fetch!(:rows)
      |> List.flatten()

    assert nullable_columns ==
             ~w(replay_ciphertext replay_erased_at replay_key_id replay_nonce replay_tag)

    definition =
      Repo.query!(
        """
        SELECT pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conname = 'conversation_ephemeral_rooms_digest_check'
        """,
        []
      )
      |> Map.fetch!(:rows)
      |> List.flatten()
      |> List.first()

    assert definition =~ "replay_ciphertext IS NULL"
    assert definition =~ "replay_nonce IS NULL"
    assert definition =~ "replay_erased_at >= idempotency_expires_at"
    assert definition =~ "octet_length(replay_tag) = 16"
    assert definition =~ "replay_erased_at IS NULL"
  end

  test "maintenance prunes only old terminal leases and 24-hour human receipts" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    subject = guest_subject(created)

    open = fn ->
      attrs =
        subject
        |> Map.put(:conversation_id, created.conversation.id)
        |> Map.put(:connection_id, secret())

      assert {:ok, result} = Conversations.open_ephemeral_presence(attrs)
      {attrs, result.lease.id}
    end

    {_live_attrs, live_id} = open.()
    {recent_attrs, recent_id} = open.()
    {old_closed_attrs, old_closed_id} = open.()
    {_old_expired_attrs, old_expired_id} = open.()
    assert {:ok, _} = Conversations.close_ephemeral_presence(recent_attrs)
    assert {:ok, _} = Conversations.close_ephemeral_presence(old_closed_attrs)

    old_seen =
      DateTime.utc_now() |> DateTime.add(-7_200, :second) |> DateTime.truncate(:microsecond)

    old_expiry = DateTime.add(old_seen, 1, :second)

    Repo.update_all(
      from(lease in EphemeralPresenceLease, where: lease.id == ^old_closed_id),
      set: [
        opened_at: DateTime.add(old_seen, -1, :second),
        last_seen_at: old_seen,
        expires_at: old_expiry,
        closed_at: old_expiry
      ]
    )

    Repo.update_all(
      from(lease in EphemeralPresenceLease, where: lease.id == ^old_expired_id),
      set: [
        opened_at: DateTime.add(old_seen, -1, :second),
        last_seen_at: old_seen,
        expires_at: old_expiry,
        closed_at: nil
      ]
    )

    human_subject = authenticated_human_fixture(account)

    assert {:ok, human_join} =
             Conversations.join_ephemeral_room(
               created.join_token,
               %{idempotency_key: secret()},
               human_subject
             )

    receipt =
      Repo.get_by!(EphemeralJoinReceipt,
        ephemeral_room_id: created.room.id,
        membership_id: human_join.membership.id
      )

    receipt_expiry =
      DateTime.utc_now() |> DateTime.add(-90_000, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(value in EphemeralJoinReceipt, where: value.id == ^receipt.id),
      set: [inserted_at: DateTime.add(receipt_expiry, -600, :second), expires_at: receipt_expiry]
    )

    Application.put_env(:comms_core, :instant_rooms_enabled, false)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, %{leases_pruned: 2, join_receipts_pruned: 1}} =
             Conversations.reconcile_ephemeral_rooms(reconciler)

    assert Repo.get(EphemeralPresenceLease, old_closed_id) == nil
    assert Repo.get(EphemeralPresenceLease, old_expired_id) == nil
    assert %EphemeralPresenceLease{} = Repo.get!(EphemeralPresenceLease, live_id)
    assert %EphemeralPresenceLease{} = Repo.get!(EphemeralPresenceLease, recent_id)
    assert Repo.get(EphemeralJoinReceipt, receipt.id) == nil
  end

  defp guest_create_attrs(tenant_id, idempotency_key) do
    configure_public_tenant!(tenant_id)

    %{
      tenant_id: tenant_id,
      idempotency_key: idempotency_key,
      display_name: "Guest host",
      device: %{name: "Guest browser", platform: "test"},
      request_id: "ephemeral-room-test"
    }
  end

  defp guest_join_attrs(idempotency_key) do
    %{
      idempotency_key: idempotency_key,
      display_name: "Joining guest",
      device: %{name: "Guest browser", platform: "test"},
      request_id: "ephemeral-room-join-test"
    }
  end

  defp guest_subject(result) do
    assert {:ok, context} =
             Accounts.guest_access_context(
               result.authentication.session_id,
               "ephemeral-presence-test"
             )

    Map.merge(context.subject, %{
      guest_admission_id: result.admission.id,
      guest_conversation_id: result.conversation.id,
      guest_history_from_sequence: result.admission.history_from_sequence
    })
  end

  defp authenticated_subject(authentication) do
    %{
      tenant_id: authentication.tenant.id,
      user_id: authentication.user.id,
      device_id: authentication.device.id,
      session_id: authentication.session_id,
      role: authentication.user.role,
      request_id: "ephemeral-human-join-test"
    }
  end

  defp password_for(email) do
    suffix =
      email
      |> String.replace_prefix("member-", "")
      |> String.replace_suffix("@example.test", "")

    "correct-horse-battery-#{suffix}"
  end

  defp authenticated_human_fixture(account) do
    member = Fixtures.user_fixture(account)

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.user.email,
        password_for(member.user.email),
        %{name: "Member browser", platform: "test"}
      )

    authenticated_subject(authentication)
  end

  defp secret,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp force_past_reconnect_grace(room_id) do
    old = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^room_id),
      set: [last_presence_at: old, inserted_at: old]
    )
  end

  defp room_generation(room_id), do: Repo.get!(EphemeralRoom, room_id).generation

  defp noncanonical_encoding(value) do
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    canonical_last = String.last(value)
    index = :binary.match(alphabet, canonical_last) |> elem(0)
    replacement = String.at(alphabet, index + 1)
    String.slice(value, 0, byte_size(value) - 1) <> replacement
  end

  defp configure_public_tenant!(tenant_id) do
    tenant = Repo.get!(CommsCore.Administration.Tenant, tenant_id)
    Application.put_env(:comms_core, :instant_rooms_enabled, true)
    Application.put_env(:comms_core, :instant_room_tenant_slug, tenant.slug)
  end

  defp restore_env(key, nil), do: Application.delete_env(:comms_core, key)
  defp restore_env(key, value), do: Application.put_env(:comms_core, key, value)
  defp decode_secret!(value), do: Base.url_decode64!(value, padding: false)
  defp sha256(value), do: :crypto.hash(:sha256, value)
end
