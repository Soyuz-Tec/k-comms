defmodule CommsIntegrations.Notifications do
  @callback deliver(map()) :: :ok | {:error, term()}
  def deliver(payload), do: adapter().deliver(payload)
  defp adapter, do: Application.get_env(:comms_integrations, :notification_adapter, CommsIntegrations.Notifications.DenyAll)
end
