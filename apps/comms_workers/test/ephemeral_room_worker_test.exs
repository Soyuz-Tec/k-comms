defmodule CommsWorkers.EphemeralRoomWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.RuntimePorts
  alias CommsWorkers.{EphemeralRoomLifecycleWorker, EphemeralRoomReconcilerWorker}

  test "runtime ports bind lifecycle work to the dedicated adapters" do
    assert RuntimePorts.job_worker!(:ephemeral_room_lifecycle) ==
             EphemeralRoomLifecycleWorker

    assert RuntimePorts.job_worker!(:ephemeral_room_reconciler) ==
             EphemeralRoomReconcilerWorker

    assert RuntimePorts.authorized_job_worker?(
             :ephemeral_room_lifecycle,
             EphemeralRoomLifecycleWorker
           )

    refute RuntimePorts.authorized_job_worker?(
             :ephemeral_room_lifecycle,
             EphemeralRoomReconcilerWorker
           )
  end

  test "workers reject malformed or unfenced room jobs" do
    invalid_jobs = [
      %Oban.Job{args: %{}},
      %Oban.Job{args: %{"room_id" => Ecto.UUID.generate()}},
      %Oban.Job{args: %{"generation" => 1}},
      %Oban.Job{args: %{"room_id" => Ecto.UUID.generate(), "generation" => -1}},
      %Oban.Job{args: %{"room_id" => Ecto.UUID.generate(), "generation" => 0}},
      %Oban.Job{args: %{"room_id" => Ecto.UUID.generate(), "generation" => "1"}}
    ]

    for job <- invalid_jobs do
      assert {:discard, :room_id_and_generation_required} =
               EphemeralRoomLifecycleWorker.perform(job)
    end

    for job <- tl(invalid_jobs) do
      assert {:discard, :room_id_and_generation_required} =
               EphemeralRoomReconcilerWorker.perform(job)
    end
  end

  test "workers schedule only on the bounded lifecycle queue" do
    room_id = Ecto.UUID.generate()

    assert {:ok, lifecycle_job} =
             %{room_id: room_id, generation: 4}
             |> EphemeralRoomLifecycleWorker.new()
             |> Ecto.Changeset.apply_action(:insert)

    assert lifecycle_job.queue == "lifecycle"
    assert lifecycle_job.max_attempts == 20

    assert {:ok, reconcile_job} =
             %{room_id: room_id, generation: 4}
             |> EphemeralRoomReconcilerWorker.new()
             |> Ecto.Changeset.apply_action(:insert)

    assert reconcile_job.queue == "lifecycle"
    assert reconcile_job.max_attempts == 20

    assert {:ok, cron_job} =
             %{}
             |> EphemeralRoomReconcilerWorker.new()
             |> Ecto.Changeset.apply_action(:insert)

    assert cron_job.queue == "lifecycle"
  end

  test "minute reconciliation remains operational while new instant rooms are disabled" do
    refute Application.fetch_env!(:comms_core, :instant_rooms_enabled)
    assert :ok = EphemeralRoomReconcilerWorker.perform(%Oban.Job{args: %{}})
  end

  test "test lifecycle values preserve the production ordering constraints" do
    heartbeat = Application.fetch_env!(:comms_core, :instant_room_presence_heartbeat_seconds)
    lease = Application.fetch_env!(:comms_core, :instant_room_presence_lease_seconds)
    grace = Application.fetch_env!(:comms_core, :instant_room_reconnect_grace_seconds)

    assert lease >= heartbeat * 3
    assert grace >= lease
    assert Application.fetch_env!(:comms_core, :instant_room_guest_idle_ttl_seconds) in 60..3_600

    assert Application.fetch_env!(
             :comms_core,
             :instant_room_registered_idle_ttl_seconds
           ) in 60..86_400

    assert Application.fetch_env!(:comms_core, :instant_room_max_participants) in 2..25
    refute Application.fetch_env!(:comms_core, :instant_rooms_enabled)
  end
end
