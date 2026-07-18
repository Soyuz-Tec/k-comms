defmodule CommsCore.Conversations.Membership do
  use CommsCore.Schema

  schema "conversation_memberships" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    field(:user_id, Ecto.UUID)
    field(:role, Ecto.Enum, values: [:member, :moderator, :owner], default: :member)
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    field(:last_read_sequence, :integer, default: 0)
    field(:lock_version, :integer, default: 1)
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
      :last_read_sequence,
      :lock_version
    ])
    |> validate_required([:tenant_id, :conversation_id, :user_id, :role, :joined_at])
    |> validate_number(:last_read_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:conversation_id, :user_id])
  end
end
