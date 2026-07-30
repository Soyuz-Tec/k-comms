defmodule CommsCore.Conversations.EphemeralRooms.Scheduler do
  @moduledoc false

  alias CommsCore.{Repo, RuntimePorts}
  alias CommsCore.Conversations.{EphemeralRoom, GuestAdmission}

  def enqueue_reconcile!(%EphemeralRoom{} = room, scheduled_at) do
    room
    |> reconcile_job(scheduled_at)
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  def enqueue_expiry!(%EphemeralRoom{} = room, scheduled_at) do
    room
    |> expiry_job(scheduled_at)
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  def enqueue_guest_admission_expiry!(%GuestAdmission{} = admission) do
    admission
    |> guest_admission_expiry_job()
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  defp reconcile_job(%EphemeralRoom{} = room, scheduled_at) do
    %{"room_id" => room.id, "generation" => room.generation}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:ephemeral_room_reconciler),
      queue: :lifecycle,
      scheduled_at: scheduled_at,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: :incomplete
      ]
    )
  end

  defp expiry_job(%EphemeralRoom{} = room, scheduled_at) do
    %{"room_id" => room.id, "generation" => room.generation}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:ephemeral_room_lifecycle),
      queue: :lifecycle,
      scheduled_at: scheduled_at,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: :incomplete
      ]
    )
  end

  defp guest_admission_expiry_job(%GuestAdmission{} = admission) do
    %{"admission_id" => admission.id, "tenant_id" => admission.tenant_id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:guest_admission_expiry),
      queue: :default,
      scheduled_at: admission.expires_at,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: :incomplete
      ]
    )
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
end
