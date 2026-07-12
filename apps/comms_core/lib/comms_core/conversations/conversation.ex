defmodule CommsCore.Conversations.Conversation do
  use CommsCore.Schema

  schema "conversations" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:created_by_user, CommsCore.Accounts.User)
    field(:kind, Ecto.Enum, values: [:direct, :group, :channel], default: :group)
    field(:title, :string)
    field(:visibility, Ecto.Enum, values: [:private, :tenant], default: :private)
    field(:direct_key, :string)
    field(:next_sequence, :integer, default: 1)
    field(:archived_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :created_by_user_id,
      :kind,
      :title,
      :visibility,
      :direct_key,
      :next_sequence,
      :archived_at,
      :lock_version
    ])
    |> validate_required([:tenant_id, :created_by_user_id, :kind, :visibility, :next_sequence])
    |> validate_number(:next_sequence, greater_than: 0)
    |> validate_length(:title, max: 160)
    |> unique_constraint(:direct_key, name: :conversations_tenant_direct_key_unique)
  end
end
