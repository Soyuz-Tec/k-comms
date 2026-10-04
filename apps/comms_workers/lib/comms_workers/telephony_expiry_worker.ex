defmodule CommsWorkers.TelephonyExpiryWorker do
  @moduledoc "Enforces persisted ringing and maximum connected-call deadlines."
  use Oban.Worker, queue: :lifecycle, max_attempts: 20

  alias CommsCore.Telephony

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"call_id" => call_id}}) when is_binary(call_id) do
    case Telephony.expire(call_id, __MODULE__) do
      {:ok, state} when state in [:expired, :already_terminal] -> :ok
      {:ok, {:not_due, seconds}} -> {:snooze, max(seconds, 1)}
      {:error, :not_found} -> {:discard, :telephony_call_not_found}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :call_id_required}

  defp safe_reason(reason) when reason in [:forbidden, :telephony_disabled], do: reason
  defp safe_reason(_reason), do: :telephony_expiry_failed
end
