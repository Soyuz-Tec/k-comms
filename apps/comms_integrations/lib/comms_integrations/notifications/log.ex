defmodule CommsIntegrations.Notifications.Log do
  @behaviour CommsIntegrations.Notifications
  require Logger

  @impl true
  def deliver(payload) do
    Logger.info("notification accepted by log adapter",
      tenant_id: value(payload, "tenant_id"),
      event_type: value(payload, "event_type")
    )

    {:ok, %{provider: "log", mode: "development"}}
  end

  @impl true
  def status, do: %{status: :degraded, adapter: "log", reason: :development_only}

  defp value(payload, "tenant_id"),
    do: Map.get(payload, "tenant_id") || Map.get(payload, :tenant_id)

  defp value(payload, "event_type"),
    do: Map.get(payload, "event_type") || Map.get(payload, :event_type)
end
