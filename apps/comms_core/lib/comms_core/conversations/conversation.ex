defmodule CommsCore.Conversations.Conversation do
  use CommsCore.Schema
  schema "conversations" do
    belongs_to :tenant, CommsCore.Accounts.Tenant
    field :kind, Ecto.Enum, values: [:direct, :group, :channel], default: :group
    field :title, :string
    field :visibility, Ecto.Enum, values: [:private, :tenant], default: :private
    field :next_sequence, :integer, default: 1
    field :archived_at, :utc_datetime_usec
    timestamps()
  end
  def changeset(value, attrs), do: value |> cast(attrs, [:tenant_id, :kind, :title, :visibility, :next_sequence, :archived_at]) |> validate_required([:tenant_id, :kind, :visibility, :next_sequence]) |> validate_number(:next_sequence, greater_than: 0)
end
