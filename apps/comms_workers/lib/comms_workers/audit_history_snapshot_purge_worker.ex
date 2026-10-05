defmodule CommsWorkers.AuditHistorySnapshotPurgeWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: 300, fields: [:worker, :args], states: [:available, :scheduled, :retryable]]

  alias CommsCore.Audit

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: perform(job, &Oban.insert/1)

  @doc false
  def perform(%Oban.Job{}, insert_job) when is_function(insert_job, 1) do
    # One bounded owner batch per execution; a demand job drains further rows.
    case Audit.purge_resource_history_snapshots(DateTime.utc_now(), 1_000) do
      %{has_more: true} ->
        case %{"continue" => true} |> new(schedule_in: 1) |> insert_job.() do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :history_snapshot_purge_scheduling_failed}
        end

      %{has_more: false} ->
        :ok
    end
  end
end
