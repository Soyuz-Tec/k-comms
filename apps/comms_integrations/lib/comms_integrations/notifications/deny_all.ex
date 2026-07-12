defmodule CommsIntegrations.Notifications.DenyAll do
  @behaviour CommsIntegrations.Notifications
  @impl true
  def deliver(_payload), do: {:error, :notification_adapter_not_configured}

  @impl true
  def status,
    do: %{status: :unavailable, adapter: "deny_all", reason: :notification_adapter_not_configured}
end
