defmodule CommsCore.Conversations.ConversationView do
  @moduledoc "Stable conversation projection for public adapters."
  defstruct [
    :id,
    :tenant_id,
    :kind,
    :title,
    :visibility,
    :latest_sequence,
    :archived_at,
    :version,
    :inserted_at,
    :updated_at,
    :membership_role,
    :last_read_sequence,
    :unread_count,
    :joined,
    :member_count,
    :membership
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          kind: :direct | :group | :channel,
          title: String.t() | nil,
          visibility: :private | :tenant,
          latest_sequence: non_neg_integer(),
          archived_at: DateTime.t() | nil,
          version: pos_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t(),
          membership_role: :member | :moderator | :owner | nil,
          last_read_sequence: non_neg_integer() | nil,
          unread_count: non_neg_integer() | nil,
          joined: boolean() | nil,
          member_count: non_neg_integer() | nil,
          membership: CommsCore.Conversations.MembershipView.t() | nil
        }
end
