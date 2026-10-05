defmodule CommsWorkers.TelephonyCleanupWorker do
  @moduledoc """
  Verifies idempotent owned PBX and room deletion before a terminal call is cleaned.

  The domain retains an enforcement horizon for a still-running SIP create
  request so a late telephone participant cannot resurrect an ended call.
  """
  use Oban.Worker, queue: :lifecycle, max_attempts: 100

  alias CommsCore.Telephony
  alias CommsCore.Telephony.ProviderCommand

  @provider_retry_seconds 15

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"call_id" => call_id}}) when is_binary(call_id) do
    case Telephony.claim_cleanup(call_id, __MODULE__) do
      {:ok, %ProviderCommand{} = command} -> cleanup(command)
      {:ok, :already_clean} -> :ok
      {:ok, {:not_due, seconds}} -> {:snooze, max(seconds, 1)}
      {:error, :not_found} -> {:discard, :telephony_call_not_found}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :call_id_required}

  defp cleanup(%ProviderCommand{} = command) do
    case Telephony.complete_cleanup(command.call_id, :execute, __MODULE__) do
      :ok ->
        :ok

      {:ok, {:not_due, seconds}} ->
        {:snooze, max(seconds, 1)}

      {:error, reason}
      when reason in [
             :telephony_provider_unavailable,
             :telephony_outcome_unknown,
             :telephony_pbx_binding_invalid
           ] ->
        {:snooze, @provider_retry_seconds}

      {:error, :not_found} ->
        {:discard, :telephony_call_not_found}

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  defp safe_reason(reason) when reason in [:forbidden, :telephony_disabled], do: reason
  defp safe_reason(_reason), do: :telephony_cleanup_failed
end
