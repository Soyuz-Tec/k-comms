defmodule CommsWorkers.RetentionReconcilerWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [
      period: 300,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias CommsCore.Governance

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, result} <-
           Governance.reconcile_retention_schedules(Map.get(args, "cursor"), __MODULE__) do
      if result.has_more do
        case %{"cursor" => result.next_cursor} |> new() |> Oban.insert() do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :retention_reconciliation_scheduling_failed}
        end
      else
        :ok
      end
    end
  end
end
