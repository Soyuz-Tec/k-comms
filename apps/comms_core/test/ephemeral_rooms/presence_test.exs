defmodule CommsCore.Conversations.EphemeralRooms.PresenceTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{Conversations, Repo, RuntimePorts}
  alias CommsCore.Conversations.{EphemeralPresenceLease, EphemeralRoom}

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

  @tag :presence
  @tag :concurrency
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

  @tag :presence
  @tag :concurrency
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

  @tag :presence
  @tag :concurrency
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

  @tag :presence
  @tag :concurrency
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
end
