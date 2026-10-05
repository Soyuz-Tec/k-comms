defmodule CommsCore.Telephony.IvrProviderPort do
  @moduledoc "Optional qualified ARI IVR port. Unavailable is the default."
  alias CommsCore.Telephony.{IvrEvent, IvrProviderRequest}

  @spec ready?() :: boolean()
  def ready? do
    case adapter() do
      {:ok, module} -> module.ready?()
      _ -> false
    end
  end

  @spec prepare(IvrProviderRequest.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(request), do: dispatch(:prepare, request)
  @spec play(IvrProviderRequest.t()) :: {:ok, :pending} | {:error, atom()}
  def play(request), do: dispatch(:play, request)

  @spec destination(IvrProviderRequest.t()) ::
          {:ok, :pending | :ready | :connected} | {:error, atom()}
  def destination(request), do: dispatch(:destination, request)

  @spec verify_event(binary(), binary()) :: {:ok, IvrEvent.t()} | {:error, atom()}
  def verify_event(body, authorization) do
    with {:ok, module} <- adapter(), do: module.verify_event(body, authorization)
  end

  defp dispatch(operation, request) do
    with {:ok, module} <- adapter(), do: apply(module, operation, [request])
  end

  defp adapter do
    with {:ok, module} <- Application.fetch_env(:comms_core, :telephony_ivr_adapter),
         true <- is_atom(module) and Code.ensure_loaded?(module),
         true <-
           Enum.all?(
             [ready?: 0, prepare: 1, play: 1, destination: 1, verify_event: 2],
             fn {operation, arity} -> function_exported?(module, operation, arity) end
           ) do
      {:ok, module}
    else
      _ -> {:error, :telephony_ivr_unavailable}
    end
  end
end
