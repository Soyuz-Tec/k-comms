defmodule CommsCore.Conversations.EphemeralRooms.LifecycleTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{
    Attachments,
    AudioCalls,
    Conversations,
    Messaging,
    Repo,
    RuntimePorts
  }

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestLink,
    Membership
  }

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  setup do
    enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    on_exit(fn ->
      restore_env(:instant_rooms_enabled, enabled)
      restore_env(:instant_room_tenant_slug, slug)
    end)

    :ok
  end

  @tag :presence
  @tag :concurrency
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

  @tag :presence
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

  @tag :presence
  @tag :concurrency
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

  @tag :presence
  @tag :messaging
  @tag :call
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

  @tag :presence
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
end
