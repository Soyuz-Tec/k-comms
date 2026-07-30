defmodule CommsCore.Conversations.EphemeralRooms.MaintenanceTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{Conversations, Repo, RuntimePorts}

  alias CommsCore.Conversations.{
    EphemeralJoinReceipt,
    EphemeralPresenceLease,
    EphemeralRoom
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

  @tag :presence
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
end
