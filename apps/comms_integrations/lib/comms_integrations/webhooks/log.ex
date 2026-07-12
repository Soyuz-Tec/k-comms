defmodule CommsIntegrations.Webhooks.Log do
  @behaviour CommsIntegrations.Webhooks
  require Logger

  @impl true
  def deliver(payload) do
    Logger.info("webhook accepted by log adapter", event_type: value(payload, "event_type"))
    :ok
  end

  defp value(payload, "event_type"),
    do: Map.get(payload, "event_type") || Map.get(payload, :event_type)
end
