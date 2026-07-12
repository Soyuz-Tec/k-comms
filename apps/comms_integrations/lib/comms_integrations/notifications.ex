defmodule CommsIntegrations.Notifications do
  @callback deliver(map()) :: :ok | {:ok, map()} | {:error, term()}
  @callback status() :: map()
  def deliver(payload), do: adapter().deliver(payload)
  def status, do: adapter().status()

  defp adapter,
    do:
      Application.get_env(
        :comms_integrations,
        :notification_adapter,
        CommsIntegrations.Notifications.DenyAll
      )
end
