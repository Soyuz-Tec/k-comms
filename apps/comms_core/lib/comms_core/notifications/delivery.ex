defmodule CommsCore.Notifications.Delivery do
  @moduledoc "Claim-scoped notification delivery command returned to the delivery worker."

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          event_type: String.t(),
          channel: atom(),
          destination: String.t(),
          payload: map(),
          idempotency_key: String.t(),
          push_subscription_id: Ecto.UUID.t() | nil,
          push_subscription_version: pos_integer() | nil,
          status: atom(),
          attempt_count: non_neg_integer(),
          claim_generation: non_neg_integer(),
          claim_token: Ecto.UUID.t() | nil
        }

  @derive {Inspect, except: [:destination, :payload, :claim_token]}
  defstruct [
    :id,
    :tenant_id,
    :user_id,
    :event_type,
    :channel,
    :destination,
    :idempotency_key,
    :push_subscription_id,
    :push_subscription_version,
    :status,
    :claim_token,
    payload: %{},
    attempt_count: 0,
    claim_generation: 0
  ]
end
