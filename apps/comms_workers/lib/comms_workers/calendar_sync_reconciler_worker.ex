defmodule CommsWorkers.CalendarSyncReconcilerWorker do
  use Oban.Worker,
    queue: :calendar,
    max_attempts: 10,
    unique: [period: 55, states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case CommsCore.AudioCalls.reconcile_calendar_commands(100, __MODULE__) do
      {:ok, _} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :calendar_reconciliation_failed}
    end
  end
end
