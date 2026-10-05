defmodule CommsCore.Conversations.PrivateContentErasureCommand do
  @moduledoc "Retained native provider-purge facts. ConversationContent must validate them with the Conversations owner before removing ciphertext."
  @enforce_keys [
    :tenant_id,
    :conversation_id,
    :generation,
    :matrix_room_id,
    :provider_purge_id,
    :timestamp
  ]
  defstruct [
    :tenant_id,
    :conversation_id,
    :generation,
    :matrix_room_id,
    :provider_purge_id,
    :timestamp
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          conversation_id: String.t(),
          generation: pos_integer(),
          matrix_room_id: String.t(),
          provider_purge_id: String.t(),
          timestamp: DateTime.t()
        }
end
