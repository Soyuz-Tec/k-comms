defmodule CommsIntegrations.Webhooks.DenyAll do
  @behaviour CommsIntegrations.Webhooks
  @impl true
  def deliver(_request), do: {:error, :webhook_adapter_not_configured}
end
