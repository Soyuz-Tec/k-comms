defmodule CommsCore.ServiceAccounts.ServiceUser do
  @moduledoc false

  use CommsCore.Schema

  schema "users" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    field(:external_subject, :string)
    field(:display_name, :string)
    field(:email, :string)
    field(:password_hash, :string, redact: true)

    field(:role, Ecto.Enum,
      values: [:member, :moderator, :admin, :compliance_admin, :security_admin, :owner],
      default: :member
    )

    field(:status, Ecto.Enum, values: [:active, :suspended, :deleted], default: :active)

    field(:platform_role, Ecto.Enum,
      values: [:platform_operator, :support_operator, :security_operator]
    )

    field(:account_type, Ecto.Enum, values: [:human, :service], default: :human)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def service_changeset(user, attrs) do
    user
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
end
