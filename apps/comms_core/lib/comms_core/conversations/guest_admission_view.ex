defmodule CommsCore.Conversations.GuestAdmissionView do
  @moduledoc "Conversation-owned projection of a temporary guest admission."

  defstruct [
    :id,
    :conversation_id,
    :guest_link_id,
    :guest_user_id,
    :membership_id,
    :session_id,
    :admitted_at,
    :expires_at,
    :revoked_at,
    :converted_at,
    :history_from_sequence
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          guest_link_id: Ecto.UUID.t(),
          guest_user_id: Ecto.UUID.t(),
          membership_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t(),
          admitted_at: DateTime.t(),
          expires_at: DateTime.t(),
          revoked_at: DateTime.t() | nil,
          converted_at: DateTime.t() | nil,
          history_from_sequence: pos_integer()
        }
end
