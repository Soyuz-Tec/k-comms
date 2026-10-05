defmodule CommsCore.Telephony.IvrProviderPort.Contract do
  @moduledoc "Exact caller-only ARI IVR protocol, including read-only uncertain reconciliation."
  alias CommsCore.Telephony.{IvrEvent, IvrProviderRequest}
  @callback ready?() :: boolean()
  @callback prepare(IvrProviderRequest.t()) :: {:ok, map()} | {:error, atom()}
  # A REST playback read has no original completion timestamp. Only an
  # authenticated provider event can open the caller's digit window.
  @callback play(IvrProviderRequest.t()) :: {:ok, :pending} | {:error, atom()}
  @callback destination(IvrProviderRequest.t()) ::
              {:ok, :pending | :ready | :connected} | {:error, atom()}
  @callback verify_event(binary(), binary()) :: {:ok, IvrEvent.t()} | {:error, atom()}
end
