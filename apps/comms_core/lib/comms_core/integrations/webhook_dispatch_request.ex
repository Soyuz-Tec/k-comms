defmodule CommsCore.Integrations.WebhookDispatchRequest do
  @moduledoc "Stable request contract for the webhook delivery adapter."

  @derive {Inspect, except: [:secret, :body]}
  @enforce_keys [:url, :secret, :body, :event_type, :delivery_id, :idempotency_key]
  defstruct [:url, :secret, :body, :event_type, :delivery_id, :idempotency_key]
end
