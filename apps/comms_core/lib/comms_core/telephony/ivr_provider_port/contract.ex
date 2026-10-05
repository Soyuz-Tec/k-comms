defmodule CommsCore.Telephony.IvrProviderPort.Contract do
  @moduledoc "Exact caller-only ARI IVR protocol, including read-only uncertain reconciliation."
  alias CommsCore.Telephony.{IvrEvent, IvrProviderRequest}
  @callback ready?() :: boolean()
  @callback prepare(IvrProviderRequest.t()) :: {:ok, map()} | {:error, atom()}
  @callback play(IvrProviderRequest.t()) :: {:ok, :pending | :completed} | {:error, atom()}
  @callback destination(IvrProviderRequest.t()) :: {:ok, :pending | :ready | :connected} | {:error, atom()}
  @callback verify_event(binary(), binary()) :: {:ok, IvrEvent.t()} | {:error, atom()}
end
