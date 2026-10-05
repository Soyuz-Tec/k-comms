defmodule CommsCore.Telephony.ProviderControlPort do
  @moduledoc "Telephony-owned advanced-control port; defaults to unavailable."
  @actions [
    :dtmf,
    :hold,
    :resume,
    :blind_transfer,
    :consult_transfer,
    :voicemail,
    :queues,
    :shared_lines
  ]
  @spec capabilities() :: map()
  def capabilities() do
    case adapter() do
      {:ok, module} -> module.capabilities()
      _ -> Map.new(@actions, &{&1, %{supported: false, reason: "provider_unavailable"}})
    end
  end

  @spec verify_event(binary(), binary()) :: {:ok, map()} | {:error, atom()}
  def verify_event(body, authorization) do
    with {:ok, module} <- adapter(), true <- function_exported?(module, :verify_event, 2) do
      module.verify_event(body, authorization)
    else
      _ -> {:error, :invalid_provider_webhook}
    end
  end

  @spec authorize_destination(String.t()) :: :ok | {:error, atom()}
  def authorize_destination(destination) do
    with {:ok, module} <- adapter(), do: module.authorize_destination(destination)
  end

  @spec execute_control(CommsCore.Telephony.ControlRequest.t()) ::
          {:ok, :submitted | map()} | {:error, atom()}
  def execute_control(request) do
    with {:ok, module} <- adapter(), true <- function_exported?(module, :execute_control, 1) do
      module.execute_control(request)
    else
      _ -> {:error, :telephony_control_unsupported}
    end
  end

  @spec cleanup_call(CommsCore.Telephony.ProviderCommand.t()) :: :ok | {:error, atom()}
  def cleanup_call(command) do
    with {:ok, module} <- adapter(), true <- function_exported?(module, :cleanup_call, 1) do
      module.cleanup_call(command)
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end

  @spec bound_call_status(CommsCore.Telephony.ProviderCommand.t()) ::
          {:ok, :active | :ended} | {:error, atom()}
  def bound_call_status(command) do
    with {:ok, module} <- adapter(), true <- function_exported?(module, :bound_call_status, 1) do
      module.bound_call_status(command)
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end

  defp adapter do
    with {:ok, module} <- Application.fetch_env(:comms_core, :telephony_control_adapter),
         true <- is_atom(module) and Code.ensure_loaded?(module),
         true <- function_exported?(module, :capabilities, 0),
         true <- function_exported?(module, :authorize_destination, 1) do
      {:ok, module}
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end
end
