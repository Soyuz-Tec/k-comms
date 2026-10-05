defmodule CommsWorkers.TelephonyRoutingWorker do
  @moduledoc "Re-evaluates bounded waiting-call assignment against current identity, DND and agent capacity."
  use Oban.Worker, queue: :lifecycle, max_attempts: 100
  alias CommsCore.Telephony
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"call_id" => id}}), do: advance(id)
  def perform(_), do: {:discard, :call_id_required}

  defp advance(id) do
    case Telephony.advance_route(id, __MODULE__) do
      {:ok, {:wait, seconds}} ->
        {:snooze, seconds}

      {:ok, state} when state in [:expired, :unavailable] ->
        case Telephony.enqueue_route_voicemail(id, __MODULE__) do
          {:ok, :voicemail} ->
            :ok

          _ ->
            case Telephony.expire_route(id, __MODULE__) do
              {:ok, _} -> :ok
              _ -> {:error, :telephony_route_expiry_failed}
            end
        end

      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        {:discard, :telephony_route_not_found}

      {:error, _} ->
        {:error, :telephony_route_failed}
    end
  end
end
