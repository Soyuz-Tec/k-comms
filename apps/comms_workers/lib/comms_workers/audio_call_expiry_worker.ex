defmodule CommsWorkers.AudioCallExpiryWorker do
  use Oban.Worker, queue: :media, max_attempts: 20

  alias CommsCore.AudioCalls
  alias CommsIntegrations.Audio.RoomService

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"call_id" => call_id}}) when is_binary(call_id) do
    case AudioCalls.expire_call(call_id, __MODULE__, &RoomService.delete_room/1) do
      {:ok, {:expired, _call}} -> :ok
      {:ok, {:already_ended, _call}} -> :ok
      {:ok, {:not_due, seconds}} -> {:snooze, max(seconds, 1)}
      {:error, :not_found} -> {:discard, :audio_call_not_found}
      {:error, :audio_call_ending} -> {:snooze, 5}
      {:error, :audio_provider_unavailable} -> {:snooze, 15}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :call_id_required}

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :audio_call_expiry_failed
end
