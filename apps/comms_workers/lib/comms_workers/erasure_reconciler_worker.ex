defmodule CommsWorkers.ErasureReconcilerWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  alias CommsCore.Governance

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Governance.reconcile_completed_erasure(__MODULE__, 100) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
