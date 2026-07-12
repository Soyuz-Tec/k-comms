defmodule CommsCore.Accounts.PasswordRecoveryRequest do
  use CommsCore.Schema

  schema "password_recovery_requests" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:user, CommsCore.Accounts.User)
    field(:token_hash, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:invalidated_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :token_hash,
      :expires_at,
      :consumed_at,
      :invalidated_at
    ])
    |> validate_required([:tenant_id, :user_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id, name: :password_recovery_requests_tenant_user_id_fk)
  end
end
