defmodule CommsCore.Telephony.ProvisioningPort.Contract do
  @moduledoc "Telephony owns provider setup; adapters return only bounded secret-free evidence."
  @callback status(String.t()) :: map()
  @callback inspect(CommsCore.Telephony.ProvisioningRequest.t()) ::
              {:ok, map()} | {:error, atom()}
  @callback apply(CommsCore.Telephony.ProvisioningRequest.t()) :: {:ok, map()} | {:error, atom()}
end
