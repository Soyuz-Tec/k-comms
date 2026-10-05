defmodule CommsCore.Conversations.PrivateRoomControlCommand do
  @moduledoc "Conversations-owned native Matrix control command. Contains immutable principal mappings, not client encryption keys."
  @enforce_keys [:tenant_id, :conversation_id, :room_alias, :members, :generation]
  defstruct [
    :tenant_id,
    :conversation_id,
    :room_alias,
    :members,
    :generation,
    :matrix_room_id,
    :removed_matrix_user_id,
    :purge_id,
    :provider_issuer,
    :provider_server_name,
    :control_matrix_user_id,
    :historical_matrix_user_ids,
    :deadline,
    allow_create?: false
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          conversation_id: String.t(),
          room_alias: String.t(),
          members: [CommsCore.Accounts.MatrixIdentityView.t()],
          generation: pos_integer(),
          matrix_room_id: String.t() | nil,
          removed_matrix_user_id: String.t() | nil,
          purge_id: String.t() | nil,
          provider_issuer: String.t(),
          provider_server_name: String.t(),
          control_matrix_user_id: String.t(),
          historical_matrix_user_ids: [String.t()],
          deadline: integer(),
          allow_create?: boolean()
        }
end
