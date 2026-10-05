defmodule CommsCore.AudioCalls.ArtifactProviderPort.Contract do
  @moduledoc "Calls-owned technical contract for an approved capture provider."
  alias CommsCore.AudioCalls.{
    ArtifactProviderRequest,
    ArtifactProviderReceipt,
    ArtifactProviderEvent
  }

  @callback configured?() :: boolean()
  @callback start(ArtifactProviderRequest.t()) ::
              {:ok, ArtifactProviderReceipt.t()} | {:error, atom()}
  @callback stop(ArtifactProviderRequest.t()) ::
              {:ok, ArtifactProviderReceipt.t()} | {:error, atom()}
  @callback reconcile(ArtifactProviderRequest.t()) ::
              {:ok, ArtifactProviderReceipt.t()} | {:error, atom()}
  @callback verify_callback(binary(), binary()) ::
              {:ok, ArtifactProviderEvent.t()} | {:error, atom()}
end
