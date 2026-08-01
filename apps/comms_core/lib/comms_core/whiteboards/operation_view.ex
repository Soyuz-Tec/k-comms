defmodule CommsCore.Whiteboards.OperationView do
  @moduledoc "Ecto-free durable whiteboard operation contract."

  @enforce_keys [
    :id,
    :whiteboard_id,
    :tenant_id,
    :conversation_id,
    :actor_user_id,
    :client_operation_id,
    :sequence,
    :kind,
    :payload,
    :inserted_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          whiteboard_id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t(),
          client_operation_id: String.t(),
          sequence: pos_integer(),
          kind: String.t(),
          payload: map(),
          inserted_at: DateTime.t()
        }
end
