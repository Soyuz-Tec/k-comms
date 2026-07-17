defmodule CommsCore.Integrations.Projector do
  @moduledoc false

  alias CommsCore.Integrations.{
    WebhookDelivery,
    WebhookDeliveryView,
    WebhookEndpoint,
    WebhookEndpointView,
    WebhookSubscription
  }

  def endpoint(%WebhookEndpoint{} = endpoint) do
    struct!(WebhookEndpointView, %{
      id: endpoint.id,
      name: endpoint.name,
      url: endpoint.url,
      status: endpoint.status,
      secret_version: endpoint.secret_version,
      event_types: subscriptions(endpoint.subscriptions),
      disabled_at: endpoint.disabled_at,
      inserted_at: endpoint.inserted_at,
      updated_at: endpoint.updated_at
    })
  end

  def delivery(%WebhookDelivery{} = delivery) do
    struct!(WebhookDeliveryView, %{
      id: delivery.id,
      endpoint_id: delivery.endpoint_id,
      event_type: delivery.event_type,
      status: delivery.status,
      attempt_count: delivery.attempt_count,
      next_attempt_at: delivery.next_attempt_at,
      last_attempt_at: delivery.last_attempt_at,
      delivered_at: delivery.delivered_at,
      response_status: delivery.response_status,
      last_error_code: delivery.last_error_code,
      inserted_at: delivery.inserted_at,
      updated_at: delivery.updated_at
    })
  end

  defp subscriptions(%Ecto.Association.NotLoaded{}), do: []

  defp subscriptions(values) when is_list(values) do
    values
    |> Enum.map(fn %WebhookSubscription{event_type: event_type} -> event_type end)
    |> Enum.sort()
  end

  defp subscriptions(_), do: []
end
