defmodule CommsCore.Telephony.ProviderWebhookPort.Contract do
  @moduledoc "Telephony-owned verification and trusted callback adapter contract."
  @callback verify_webhook(binary(), binary()) :: {:ok, map()} | {:error, atom()}
  @callback authorized_adapter?(module()) :: boolean()
end
