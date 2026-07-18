defmodule CommsCore.Integrations.WebhookEndpointView do
  @moduledoc "Stable webhook endpoint projection without secret persistence state."
  defstruct [
    :id,
    :name,
    :url,
    :status,
    :secret_version,
    :event_types,
    :disabled_at,
    :inserted_at,
    :updated_at
  ]
end
