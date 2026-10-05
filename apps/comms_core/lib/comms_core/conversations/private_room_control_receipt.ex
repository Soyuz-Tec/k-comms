defmodule CommsCore.Conversations.PrivateRoomControlReceipt do
  @enforce_keys [:matrix_room_id]
  defstruct [:matrix_room_id, :purge_id, :provider_purged?, :joined_matrix_user_ids]

  @type t :: %__MODULE__{
          matrix_room_id: String.t(),
          purge_id: String.t() | nil,
          provider_purged?: boolean() | nil,
          joined_matrix_user_ids: [String.t()] | nil
        }
end
