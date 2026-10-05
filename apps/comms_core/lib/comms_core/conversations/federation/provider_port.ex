defmodule CommsCore.Conversations.Federation.ProviderPort do
  alias CommsCore.Conversations.Federation.{ProviderRequest, ProviderReceipt}
  @callback perform(ProviderRequest.t()) :: {:ok, ProviderReceipt.t()} | {:error, atom()}
end
