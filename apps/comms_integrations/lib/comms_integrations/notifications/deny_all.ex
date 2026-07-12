defmodule CommsIntegrations.Notifications.DenyAll do
  @behaviour CommsIntegrations.Notifications
  @impl true
  def deliver(_payload), do: {:error, :notification_adapter_not_configured}
end
