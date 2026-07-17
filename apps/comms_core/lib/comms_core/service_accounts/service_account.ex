defmodule CommsCore.ServiceAccounts.ServiceAccount do
  use CommsCore.Schema

  @scopes ["conversations:read", "messages:read", "messages:write", "search:read"]

  schema "service_accounts" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:user, CommsCore.Accounts.User)
    belongs_to(:device, CommsCore.Accounts.Device)
    belongs_to(:created_by_user, CommsCore.Accounts.User)
    field(:name, :string)
    field(:credential_prefix, :string)
    field(:secret_hash, :binary, redact: true)
    field(:secret_hint, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:status, Ecto.Enum, values: [:active, :revoked, :expired], default: :active)
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:last_rotated_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:credential_generation, :integer, default: 1)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def scopes, do: @scopes

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :device_id,
      :created_by_user_id,
      :name,
      :credential_prefix,
      :secret_hash,
      :secret_hint,
      :scopes,
      :status,
      :expires_at,
      :last_used_at,
      :last_rotated_at,
      :revoked_at,
      :credential_generation,
      :lock_version
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :device_id,
      :created_by_user_id,
      :name,
      :credential_prefix,
      :secret_hash,
      :secret_hint,
      :scopes,
      :status,
      :expires_at,
      :last_rotated_at,
      :credential_generation,
      :lock_version
    ])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:secret_hint, is: 4)
    |> validate_length(:scopes, min: 1, max: length(@scopes))
    |> validate_change(:scopes, fn :scopes, values ->
      if Enum.all?(values, &(&1 in @scopes)) and length(values) == length(Enum.uniq(values)),
        do: [],
        else: [scopes: "contain unsupported or duplicate values"]
    end)
    |> validate_number(:credential_generation, greater_than: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> unique_constraint(:user_id)
    |> unique_constraint(:device_id)
    |> check_constraint(:status, name: :service_accounts_status_allowed)
    |> check_constraint(:secret_hash, name: :service_accounts_secret_hash_shape)
    |> check_constraint(:credential_prefix, name: :service_accounts_credential_prefix_shape)
    |> check_constraint(:secret_hint, name: :service_accounts_secret_hint_shape)
    |> check_constraint(:scopes, name: :service_accounts_scopes_allowed)
    |> check_constraint(:expires_at, name: :service_accounts_expiry_after_creation)
    |> check_constraint(:revoked_at, name: :service_accounts_revocation_consistent)
    |> check_constraint(:lock_version, name: :service_accounts_versions_positive)
  end
end
