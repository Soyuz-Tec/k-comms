defmodule CommsCore.Accounts.Device do
  use CommsCore.Schema
  schema "devices" do
    belongs_to :tenant, CommsCore.Accounts.Tenant
    belongs_to :user, CommsCore.Accounts.User
    field :name, :string
    field :platform, :string
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end
  def changeset(value, attrs), do: value |> cast(attrs, [:tenant_id, :user_id, :name, :platform, :revoked_at]) |> validate_required([:tenant_id, :user_id, :name, :platform])
end
