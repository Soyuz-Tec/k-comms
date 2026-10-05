defmodule CommsWorkers.MeetingReminderWorker do
  use Oban.Worker, queue: :media, max_attempts: 10
  alias CommsCore.AudioCalls

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"occurrence_id" => occurrence_id, "version" => version}}) do
    case AudioCalls.deliver_meeting_reminder(occurrence_id, version, __MODULE__) do
      {:ok, _} -> :ok
      {:error, :meeting_reminder_not_due} -> {:snooze, 60}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_), do: {:discard, :invalid_meeting_reminder}
end
