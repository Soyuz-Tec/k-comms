defmodule CommsWorkers.FederationReconcilerWorker do
  use Oban.Worker, queue: :lifecycle, max_attempts: 5
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case CommsCore.Conversations.reconcile_federation_commands(__MODULE__) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
