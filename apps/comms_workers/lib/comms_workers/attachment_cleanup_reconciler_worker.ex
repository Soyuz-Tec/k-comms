defmodule CommsWorkers.AttachmentCleanupReconcilerWorker do
  @moduledoc """
  Periodically restores abandoned-upload cleanup convergence.

  The core performs the bounded, locked scan and enqueues tenant-bound purge
  jobs transactionally. This worker intentionally owns no attachment schemas.
  """

  use Oban.Worker, queue: :media, max_attempts: 10, unique: [period: 55]

  alias CommsCore.Attachments

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Attachments.reconcile_abandon_cleanups(__MODULE__) do
      {:ok, _counts} -> :ok
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :attachment_cleanup_reconciliation_failed
end
