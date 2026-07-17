defmodule CommsCore.Accounts.User do
  use CommsCore.Schema

  schema "users" do
    field(:tenant_id, Ecto.UUID)
    has_one(:platform_role_grant, CommsCore.Accounts.PlatformRoleGrant)
    field(:external_subject, :string)
    field(:display_name, :string)
    field(:email, :string)
    field(:password_hash, :string, redact: true)
    field(:account_type, Ecto.Enum, values: [:human, :service], default: :human)

    field(:role, Ecto.Enum,
      values: [:member, :moderator, :admin, :compliance_admin, :security_admin, :owner],
      default: :member
    )

    field(:status, Ecto.Enum, values: [:active, :suspended, :deleted], default: :active)

    field(:platform_role, Ecto.Enum,
      values: [:platform_operator, :support_operator, :security_operator]
    )

    # Expiring grants live in platform_role_grants. This virtual field lets
    # authenticated projections carry the effective deadline without reviving
    # the rollback-only users.platform_role column.
    field(:platform_role_expires_at, :utc_datetime_usec, virtual: true)

    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :external_subject,
      :display_name,
      :email,
      :password_hash,
      :account_type,
      :role,
      :status,
      :lock_version
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([
      :tenant_id,
      :external_subject,
      :display_name,
      :email,
      :role,
      :status
    ])
    |> check_constraint(:account_type, name: :users_account_type_allowed)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_change(:email, fn :email, email ->
      if is_binary(email) and String.ends_with?(String.downcase(email), "@service.invalid"),
        do: [email: "uses a reserved service-identity domain"],
        else: []
    end)
    |> validate_length(:display_name, min: 1, max: 120)
    |> unique_constraint([:tenant_id, :external_subject])
    |> unique_constraint(:email, name: :users_tenant_email_unique)
  end

  # Service identities share the canonical users table and schema, but their
  # reserved email domain and fixed role require a narrower creation contract
  # than the human-user changeset.
  def service_changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :external_subject,
      :display_name,
      :email,
      :role,
      :status,
      :account_type,
      :lock_version
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([
      :tenant_id,
      :external_subject,
      :display_name,
      :email,
      :role,
      :status,
      :account_type
    ])
    |> validate_length(:display_name, min: 2, max: 120)
    |> validate_format(:email, ~r/@service\.invalid$/)
    |> validate_inclusion(:account_type, [:service])
    |> validate_inclusion(:role, [:member])
    |> unique_constraint([:tenant_id, :external_subject])
    |> unique_constraint(:email, name: :users_tenant_email_unique)
    |> check_constraint(:account_type, name: :users_account_type_allowed)
  end

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(value), do: value
end
