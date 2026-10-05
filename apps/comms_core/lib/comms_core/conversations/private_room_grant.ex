defmodule CommsCore.Conversations.PrivateRoomGrant do
  @moduledoc "Retained current-identity, room mode, membership, generation and provenance facts for opaque ConversationContent."
  @enforce_keys [
    :tenant_id,
    :conversation_id,
    :user_id,
    :device_id,
    :session_id,
    :matrix_room_id,
    :matrix_user_id,
    :membership_epoch,
    :generation,
    :historical_user_ids,
    :deadline
  ]
  defstruct [
    :tenant_id,
    :conversation_id,
    :user_id,
    :device_id,
    :session_id,
    :matrix_room_id,
    :matrix_user_id,
    :membership_epoch,
    :generation,
    :historical_user_ids,
    :deadline
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          conversation_id: String.t(),
          user_id: String.t(),
          device_id: String.t(),
          session_id: String.t(),
          matrix_room_id: String.t(),
          matrix_user_id: String.t(),
          membership_epoch: pos_integer(),
          generation: pos_integer(),
          historical_user_ids: [String.t()],
          deadline: integer()
        }
end
