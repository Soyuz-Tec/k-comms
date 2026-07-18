defmodule CommsCore.Conversations.MembershipView do
  @moduledoc "Stable conversation-membership projection."
  defstruct [
    :id,
    :user_id,
    :role,
    :joined_at,
    :left_at,
    :last_read_sequence,
    :version,
    :user
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          role: :member | :moderator | :owner,
          joined_at: DateTime.t(),
          left_at: DateTime.t() | nil,
          last_read_sequence: non_neg_integer(),
          version: pos_integer(),
          user: CommsCore.Accounts.UserView.t() | nil
        }
end
