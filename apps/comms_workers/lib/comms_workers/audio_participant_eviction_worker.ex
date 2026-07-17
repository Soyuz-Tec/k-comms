defmodule CommsWorkers.AudioParticipantEvictionWorker do
  use Oban.Worker, queue: :media, max_attempts: 20

  alias CommsCore.AudioCalls
  alias CommsIntegrations.Audio.RoomService

  @successful_enforcement_interval_seconds 30
  @provider_retry_interval_seconds 15

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"participant_id" => participant_id}})
      when is_binary(participant_id) do
    case AudioCalls.claim_participant_eviction(participant_id, __MODULE__) do
      {:ok, :enforcement_complete} ->
        :ok

      {:ok, claim} ->
        enforce(claim)

      {:error, :not_claimable} ->
        :ok

      {:error, :not_found} ->
        {:discard, :participant_not_found}

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :participant_id_required}

  defp enforce(claim) do
    attempt_started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case RoomService.remove_participant(claim.call, claim.provider_identity) do
      :ok ->
        record_and_schedule(
          claim.participant_id,
          :removed,
          attempt_started_at,
          @successful_enforcement_interval_seconds
        )

      {:error, _provider_reason} ->
        record_and_schedule(
          claim.participant_id,
          :failed,
          attempt_started_at,
          @provider_retry_interval_seconds
        )

      _unexpected ->
        record_and_schedule(
          claim.participant_id,
          :failed,
          attempt_started_at,
          @provider_retry_interval_seconds
        )
    end
  end

  defp record_and_schedule(participant_id, result, attempt_started_at, interval_seconds) do
    case AudioCalls.record_participant_eviction(
           participant_id,
           result,
           attempt_started_at,
           __MODULE__
         ) do
      {:ok, %{eviction_status: :completed}} -> :ok
      {:ok, _participant} -> {:snooze, interval_seconds}
      {:error, :not_found} -> {:discard, :participant_not_found}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :audio_participant_eviction_failed
end
