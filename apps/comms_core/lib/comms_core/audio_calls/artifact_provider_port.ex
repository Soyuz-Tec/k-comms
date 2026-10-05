defmodule CommsCore.AudioCalls.ArtifactProviderPort do
  @moduledoc "Calls-owned port for explicit recording and authenticated provider convergence."
  alias CommsCore.AudioCalls.{
    ArtifactProviderRequest,
    ArtifactProviderReceipt,
    ArtifactProviderEvent
  }

  @spec configured?() :: boolean()
  def configured?() do
    case adapter() do
      {:ok, adapter} -> adapter.configured?()
      _ -> false
    end
  end

  @spec start(ArtifactProviderRequest.t()) ::
          {:ok, ArtifactProviderReceipt.t()} | {:error, atom()}
  def start(%ArtifactProviderRequest{} = request), do: dispatch(:start, request)
  @spec stop(ArtifactProviderRequest.t()) :: {:ok, ArtifactProviderReceipt.t()} | {:error, atom()}
  def stop(%ArtifactProviderRequest{} = request), do: dispatch(:stop, request)

  @spec reconcile(ArtifactProviderRequest.t()) ::
          {:ok, ArtifactProviderReceipt.t()} | {:error, atom()}
  def reconcile(%ArtifactProviderRequest{} = request), do: dispatch(:reconcile, request)
  @spec verify_callback(binary(), binary()) :: {:ok, ArtifactProviderEvent.t()} | {:error, atom()}
  def verify_callback(body, authorization) when is_binary(body) and is_binary(authorization) do
    with {:ok, adapter} <- adapter(),
         {:ok, %ArtifactProviderEvent{} = event} <- adapter.verify_callback(body, authorization) do
      {:ok, event}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_provider_webhook}
    end
  end

  def verify_callback(_, _), do: {:error, :invalid_provider_webhook}

  defp dispatch(operation, request) do
    with {:ok, adapter} <- adapter(),
         {:ok, %ArtifactProviderReceipt{} = receipt} <- apply(adapter, operation, [request]),
         true <-
           receipt.provider_room == request.provider_room and
             receipt.object_key == request.object_key,
         true <-
           is_binary(receipt.provider_job_id) and byte_size(receipt.provider_job_id) in 1..200,
         true <- receipt.state in [:recording, :processing, :available, :failed] do
      {:ok, receipt}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :artifact_provider_contract_invalid}
    end
  end

  defp adapter do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :artifact_provider_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <-
           Enum.all?(
             [configured?: 0, start: 1, stop: 1, reconcile: 1, verify_callback: 2],
             fn {name, arity} -> function_exported?(adapter, name, arity) end
           ) do
      {:ok, adapter}
    else
      _ -> {:error, :artifact_provider_unavailable}
    end
  end
end
