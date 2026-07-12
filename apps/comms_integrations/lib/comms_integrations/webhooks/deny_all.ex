defmodule CommsIntegrations.Webhooks.DenyAll do
  @behaviour CommsIntegrations.Webhooks
  @impl true
  def deliver(_request), do: {:error, :webhook_adapter_not_configured}

  @impl true
  def status,
    do: %{status: :unavailable, adapter: "deny_all", reason: :webhook_adapter_not_configured}
end
