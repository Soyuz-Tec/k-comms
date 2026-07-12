defmodule CommsCore.Accounts.Session do
  use CommsCore.Schema

  schema "sessions" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:user, CommsCore.Accounts.User)
    belongs_to(:device, CommsCore.Accounts.Device)
    field(:refresh_token_hash, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :device_id,
      :refresh_token_hash,
      :expires_at,
      :last_used_at,
      :revoked_at
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :device_id,
      :refresh_token_hash,
      :expires_at,
      :last_used_at
    ])
  end
end
