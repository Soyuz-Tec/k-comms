defmodule CommsWorkers.EphemeralRoomLifecycleWorkerTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Conversations.EphemeralRoom
  alias CommsTestSupport.Fixtures

  alias CommsWorkers.{
    EphemeralRoomLifecycleWorker,
    EphemeralRoomReconcilerWorker
  }

  setup do
    account = Fixtures.account_fixture()
    previous_enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    previous_tenant_slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    Application.put_env(:comms_core, :instant_rooms_enabled, true)
    Application.put_env(:comms_core, :instant_room_tenant_slug, account.tenant.slug)

    on_exit(fn ->
      if is_nil(previous_enabled),
        do: Application.delete_env(:comms_core, :instant_rooms_enabled),
        else: Application.put_env(:comms_core, :instant_rooms_enabled, previous_enabled)

      if is_nil(previous_tenant_slug),
        do: Application.delete_env(:comms_core, :instant_room_tenant_slug),
        else:
          Application.put_env(
            :comms_core,
            :instant_room_tenant_slug,
            previous_tenant_slug
          )
    end)

    {:ok, account: account}
  end

  test "generation-fenced workers reconcile, snooze, expire, and terminate idempotently",
       %{account: account} do
    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{
                 tenant_id: account.tenant.id,
                 idempotency_key: secret(),
                 display_name: "Worker host",
                 device: %{name: "Worker test browser", platform: "test"},
                 request_id: "ephemeral-room-worker-test"
               },
               :guest
             )

    room_id = created.room.id
    initial_generation = Repo.get!(EphemeralRoom, room_id).generation
    age_room_beyond_grace(room_id)

    reconcile_job = job(room_id, initial_generation)
    assert :ok = EphemeralRoomReconcilerWorker.perform(reconcile_job)

    idle = Repo.get!(EphemeralRoom, room_id)
    assert idle.status == :idle
    assert idle.generation == initial_generation + 1

    assert :ok = EphemeralRoomReconcilerWorker.perform(reconcile_job)
    assert Repo.get!(EphemeralRoom, room_id).status == :idle

    expiry_job = job(room_id, idle.generation)
    assert {:snooze, seconds} = EphemeralRoomLifecycleWorker.perform(expiry_job)
    assert seconds in 1..60

    assert :ok =
             EphemeralRoomLifecycleWorker.perform(job(room_id, initial_generation))

    assert Repo.get!(EphemeralRoom, room_id).status == :idle

    expire_room!(idle)
    assert :ok = EphemeralRoomLifecycleWorker.perform(expiry_job)
    assert :ok = EphemeralRoomLifecycleWorker.perform(expiry_job)

    expired = Repo.get!(EphemeralRoom, room_id)
    assert expired.status == :expired
    assert expired.generation == idle.generation + 1
    assert expired.expired_at
  end

  test "unknown generation-fenced jobs are discarded without retries" do
    for room_id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert {:discard, :ephemeral_room_not_found} =
               EphemeralRoomReconcilerWorker.perform(job(room_id, 1))

      assert {:discard, :ephemeral_room_not_found} =
               EphemeralRoomLifecycleWorker.perform(job(room_id, 1))
    end
  end

  defp job(room_id, generation),
    do: %Oban.Job{args: %{"room_id" => room_id, "generation" => generation}}

  defp age_room_beyond_grace(room_id) do
    timestamp = now()
    old_timestamp = DateTime.add(timestamp, -10, :second)

    from(room in EphemeralRoom, where: room.id == ^room_id)
    |> Repo.update_all(set: [inserted_at: old_timestamp, updated_at: old_timestamp])
  end

  defp expire_room!(room) do
    timestamp = now()

    from(candidate in EphemeralRoom, where: candidate.id == ^room.id)
    |> Repo.update_all(
      set: [
        idle_since: DateTime.add(timestamp, -120, :second),
        expires_at: DateTime.add(timestamp, -1, :second)
      ]
    )
  end

  defp secret,
    do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
