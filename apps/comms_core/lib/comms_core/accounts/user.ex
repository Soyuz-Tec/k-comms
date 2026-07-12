defmodule CommsCore.Accounts.User do
  use CommsCore.Schema
  schema "users" do
    belongs_to :tenant, CommsCore.Accounts.Tenant
    field :external_subject, :string
    field :display_name, :string
    field :email, :string
    field :status, Ecto.Enum, values: [:active, :suspended, :deleted], default: :active
    timestamps()
  end
  def changeset(value, attrs), do: value |> cast(attrs, [:tenant_id, :external_subject, :display_name, :email, :status]) |> validate_required([:tenant_id, :external_subject, :display_name, :status]) |> unique_constraint([:tenant_id, :external_subject])
end
