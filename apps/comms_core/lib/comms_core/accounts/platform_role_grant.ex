defmodule CommsCore.Accounts.PlatformRoleGrant do
  use CommsCore.Schema

  @roles [:platform_operator, :support_operator, :security_operator]

  schema "platform_role_grants" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:user, CommsCore.Accounts.User)
    field(:role, Ecto.Enum, values: @roles)
    field(:expires_at, :utc_datetime_usec)
    timestamps()
  end

  def roles, do: @roles

  def active_at?(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = timestamp),
    do: DateTime.compare(expires_at, timestamp) == :gt

  def active_at?(_grant, _timestamp), do: false

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:id, :tenant_id, :user_id, :role, :expires_at])
    |> validate_required([:id, :tenant_id, :user_id, :role, :expires_at])
    |> unique_constraint(:user_id)
    |> check_constraint(:role, name: :platform_role_grants_role_allowed)
    |> check_constraint(:expires_at, name: :platform_role_grants_expiry_after_creation)
  end
end
