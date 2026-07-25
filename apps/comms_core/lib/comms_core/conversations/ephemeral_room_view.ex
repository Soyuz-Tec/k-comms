defmodule CommsCore.Conversations.EphemeralRoomView do
  @moduledoc "Persistence-free public projection for an instant communication room."

  @enforce_keys [
    :id,
    :conversation_id,
    :owner_user_id,
    :status,
    :owner_kind,
    :participant_limit,
    :inserted_at,
    :updated_at
  ]

  defstruct [
    :id,
    :conversation_id,
    :owner_user_id,
    :status,
    :owner_kind,
    :participant_limit,
    :idle_since,
    :expires_at,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          owner_user_id: Ecto.UUID.t(),
          status: :active | :idle | :expired,
          owner_kind: :guest | :registered,
          participant_limit: pos_integer(),
          idle_since: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
