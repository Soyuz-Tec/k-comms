defmodule CommsWorkers.PersonalContentCleanupWorker do
  @moduledoc "Scrubs expired synchronized draft bodies while retaining optimistic-version tombstones."
  use Oban.Worker, queue: :default, max_attempts: 10, unique: [period: 3_500]
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case CommsCore.Messaging.prune_expired_drafts(__MODULE__) do
      {:ok, _} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :draft_cleanup_failed}
    end
  end
end
