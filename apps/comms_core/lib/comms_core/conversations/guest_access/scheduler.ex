defmodule CommsCore.Conversations.GuestAccess.Scheduler do
  @moduledoc false

  alias CommsCore.{Repo, RuntimePorts}
  alias CommsCore.Conversations.GuestAdmission

  def enqueue_expiry!(%GuestAdmission{} = admission) do
    admission
    |> expiry_job()
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  defp expiry_job(%GuestAdmission{} = admission) do
    %{
      "admission_id" => admission.id,
      "tenant_id" => admission.tenant_id
    }
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:guest_admission_expiry),
      queue: :default,
      scheduled_at: admission.expires_at,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
end
