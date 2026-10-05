defmodule CommsCore.Conversations.PrivateRoomView do
  @moduledoc "Private room metadata is server-readable; message plaintext and private keys are not included."
  @enforce_keys [
    :id,
    :tenant_id,
    :title,
    :matrix_room_id,
    :state,
    :membership_epoch,
    :generation,
    :members,
    :role,
    :control_matrix_user_id
  ]
  defstruct [
    :id,
    :tenant_id,
    :title,
    :matrix_room_id,
    :state,
    :membership_epoch,
    :generation,
    :members,
    :role,
    :control_matrix_user_id
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          title: String.t(),
          matrix_room_id: String.t() | nil,
          state: atom(),
          membership_epoch: pos_integer(),
          generation: pos_integer(),
          members: [CommsCore.Accounts.MatrixIdentityView.t()],
          role: :member | :owner,
          control_matrix_user_id: String.t()
        }
end
