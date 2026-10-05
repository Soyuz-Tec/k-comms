defmodule CommsWorkers.TelephonyIvrWorker do
  @moduledoc "Advances a bounded caller menu and consumes once-issued effect claims."
  use Oban.Worker, queue: :lifecycle, max_attempts: 100
  alias CommsCore.Telephony
  alias CommsCore.Telephony.IvrEffectClaim

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => id}}) when is_binary(id) do
    Telephony.advance_ivr(id, __MODULE__) |> finish(2)
  end

  def perform(_), do: {:discard, :run_id_required}

  defp finish({:ok, {:effect, %IvrEffectClaim{} = claim}}, remaining) when remaining > 0,
    do: Telephony.execute_ivr_claim(claim, __MODULE__) |> finish(remaining - 1)

  defp finish({:ok, {:wait, seconds}}, _remaining), do: {:snooze, seconds}
  defp finish({:ok, :complete}, _remaining), do: :ok
  defp finish({:ok, _}, _remaining), do: {:snooze, 1}
  defp finish({:error, :not_found}, _remaining), do: {:discard, :telephony_ivr_not_found}

  defp finish({:error, reason}, _remaining)
       when reason in [:telephony_ivr_retry, :telephony_ivr_claim_consumed],
       do: {:snooze, 1}

  defp finish({:error, _}, _remaining), do: {:error, :telephony_ivr_unavailable}
end
