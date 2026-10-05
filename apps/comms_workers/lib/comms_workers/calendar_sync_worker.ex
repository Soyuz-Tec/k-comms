defmodule CommsWorkers.CalendarSyncWorker do
  use Oban.Worker,
    queue: :calendar,
    max_attempts: 20,
    unique: [
      period: 60,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"command_id" => id, "consent_generation" => generation}}) do
    case CommsCore.AudioCalls.perform_calendar_command(id, generation, __MODULE__) do
      {:ok, _} ->
        :ok

      {:error, reason} when reason in [:calendar_legal_hold, :calendar_cleanup_pending] ->
        {:snooze, 60}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :calendar_command_failed}
    end
  end

  def perform(_), do: {:discard, :invalid_calendar_command}
end
