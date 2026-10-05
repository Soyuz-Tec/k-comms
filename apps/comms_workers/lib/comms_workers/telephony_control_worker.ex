defmodule CommsWorkers.TelephonyControlWorker do
  @moduledoc "Claims exact SIP REFER commands once; uncertain outcomes are never redialed or retransferred."
  use Oban.Worker, queue: :telephony, max_attempts: 20
  alias CommsCore.Telephony
  alias CommsCore.Telephony.ControlRequest
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"command_id" => id}}) when is_binary(id) do
    case Telephony.claim_control(id, __MODULE__) do
      {:ok, %ControlRequest{} = command} ->
        with {:ok, bindings} <- CommsIntegrations.Telephony.prepare_control(command),
             {:ok, prepared} <- persist_bindings(command, bindings) do
          case Telephony.complete_control(id, {:execute, prepared.reconcile}, __MODULE__) do
            {:ok, :snooze} -> {:snooze, 2}
            {:ok, _} -> :ok
            {:error, _} -> {:error, :telephony_control_completion_failed}
          end
        else
          {:error, _} -> {:error, :telephony_control_preparation_failed}
        end

      {:ok, state} when state in [:already_claimed, :already_complete] ->
        :ok

      {:error, :not_found} ->
        {:discard, :telephony_control_not_found}

      {:error, _} ->
        {:error, :telephony_control_claim_failed}
    end
  end

  def perform(_), do: {:discard, :command_id_required}
  defp persist_bindings(command, nil), do: {:ok, command}

  defp persist_bindings(command, bindings) do
    case Telephony.bind_control(command.command_id, bindings, __MODULE__) do
      {:ok, prepared} -> {:ok, %{prepared | reconcile: command.reconcile}}
      error -> error
    end
  end
end
