defmodule CommsIntegrations.Webhooks do
  @callback deliver(map()) :: :ok | {:error, term()}
  def deliver(request), do: adapter().deliver(request)
  defp adapter, do: Application.get_env(:comms_integrations, :webhook_adapter, CommsIntegrations.Webhooks.DenyAll)
end
