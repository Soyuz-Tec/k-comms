defmodule CommsCore.Conversations.Federation.ProviderRequest do
  @moduledoc "Capability-limited request to the fixed Matrix client-server origin. Never log payloads."
  @derive {Inspect, only: [:operation, :transaction_id, :deadline]}
  @enforce_keys [:operation, :transaction_id, :deadline]
  defstruct [
    :operation,
    :transaction_id,
    :deadline,
    :room_id,
    :alias_localpart,
    :homeserver_origin,
    :server_name,
    :bridge_user,
    :effect_mode,
    :source_transaction_id,
    :principal,
    :event_id,
    :body,
    :cursor,
    :limit,
    allowed_servers: [],
    allowed_principals: []
  ]

  @type t :: %__MODULE__{}
end
