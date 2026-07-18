defmodule CommsCore.Integrations.WebhookDeliveryView do
  @moduledoc "Stable webhook delivery status projection without payload or claim state."
  defstruct [
    :id,
    :endpoint_id,
    :event_type,
    :status,
    :attempt_count,
    :next_attempt_at,
    :last_attempt_at,
    :delivered_at,
    :response_status,
    :last_error_code,
    :inserted_at,
    :updated_at
  ]
end
