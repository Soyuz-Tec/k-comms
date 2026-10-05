defmodule CommsWorkers.CallArtifactReconcilerWorker do
  @moduledoc "Recovers unfinished artifact work and retention without provider auto capture."
  use Oban.Worker,
    queue: :media,
    max_attempts: 10,
    unique: [period: 55, states: [:available, :scheduled, :executing, :retryable]]

  alias CommsCore.AudioCalls
  @impl true
  def perform(%Oban.Job{}) do
    case AudioCalls.reconcile_artifacts(__MODULE__) do
      {:ok, _} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :artifact_reconciliation_failed}
    end
  end
end
