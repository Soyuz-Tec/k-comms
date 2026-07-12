defmodule CommsCore.Accounts.Tenant do
  use CommsCore.Schema
  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :status, Ecto.Enum, values: [:active, :suspended, :deleting], default: :active
    timestamps()
  end
  def changeset(value, attrs), do: value |> cast(attrs, [:name, :slug, :status]) |> validate_required([:name, :slug, :status]) |> unique_constraint(:slug)
end
