defmodule CommsWorkers.TelephonyDispatchWorker do
  @moduledoc """
  Dispatches a single persisted telephone leg after the browser has joined.

  SIP participant creation is not idempotent. The domain persists the claim
  before this worker calls the provider; a resumed claim only reconciles that
  exact participant and never creates another telephone leg.

  Inbound calls only reconcile an existing SIP participant. A browser joining
  its room does not establish that the telephone leg has answered.
  """
  use Oban.Worker, queue: :telephony, max_attempts: 20

  alias CommsCore.Telephony
  alias CommsCore.Telephony.ProviderCommand
  alias CommsIntegrations.Telephony, as: Provider

  @reconciliation_interval_seconds 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"call_id" => call_id}}) when is_binary(call_id) do
    case Telephony.claim_dispatch(call_id, __MODULE__) do
      {:ok, %ProviderCommand{direction: :inbound} = command} -> reconcile(command)
      {:ok, %ProviderCommand{reconcile: true} = command} -> reconcile(command)
      {:ok, %ProviderCommand{} = command} -> dispatch(command)
      {:ok, {:not_ready, seconds}} -> {:snooze, max(seconds, 1)}
      {:ok, state} when state in [:already_terminal, :already_dispatched] -> :ok
      {:error, :not_found} -> {:discard, :telephony_call_not_found}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :call_id_required}

  defp dispatch(%ProviderCommand{} = command) do
    command
    |> Provider.create_outbound()
    |> normalize_result()
    |> complete(command.call_id)
  end

  defp reconcile(%ProviderCommand{} = command) do
    case Provider.get_participant(command.provider_room, command.provider_identity) do
      {:ok, %{state: :answered} = participant} ->
        complete({:ok, participant}, command.call_id)

      {:ok, %{state: :ended}} ->
        complete({:error, :no_answer}, command.call_id)

      # An absent participant cannot prove that an earlier CreateSIPParticipant
      # request will not arrive later. Expiry owns the deadline and cleanup.
      _pending_or_unavailable ->
        complete(:pending, command.call_id)
    end
  end

  defp complete(result, call_id) do
    case Telephony.complete_dispatch(call_id, result, __MODULE__) do
      {:ok, :pending} -> {:snooze, @reconciliation_interval_seconds}
      {:ok, _state} -> :ok
      {:error, :not_found} -> {:discard, :telephony_call_not_found}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  defp normalize_result({:ok, %{state: :answered} = participant}), do: {:ok, participant}

  defp normalize_result({:error, reason}) when reason in [:busy, :no_answer, :declined],
    do: {:error, reason}

  defp normalize_result({:error, :telephony_provider_unavailable}),
    do: {:error, :provider_unavailable}

  defp normalize_result(_unexpected_or_uncertain), do: {:error, :outcome_unknown}

  defp safe_reason(reason) when reason in [:forbidden, :telephony_disabled], do: reason
  defp safe_reason(_reason), do: :telephony_dispatch_failed
end
