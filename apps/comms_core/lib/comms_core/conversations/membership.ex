defmodule CommsCore.Conversations.Membership do
  use CommsCore.Schema

  schema "conversation_memberships" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    belongs_to(:user, CommsCore.Accounts.User)
    field(:role, Ecto.Enum, values: [:member, :moderator, :owner], default: :member)
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    field(:last_read_sequence, :integer, default: 0)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :user_id,
      :role,
      :joined_at,
      :left_at,
      :last_read_sequence
    ])
    |> validate_required([:tenant_id, :conversation_id, :user_id, :role, :joined_at])
    |> validate_number(:last_read_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:conversation_id, :user_id])
  end
end
