defmodule CommsCore.Accounts.Session do
  use CommsCore.Schema

  schema "sessions" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:user, CommsCore.Accounts.User)
    belongs_to(:device, CommsCore.Accounts.Device)
    field(:refresh_token_hash, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:absolute_expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:step_up_at, :utc_datetime_usec)
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
      :absolute_expires_at,
      :last_used_at,
      :revoked_at,
      :step_up_at
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :device_id,
      :refresh_token_hash,
      :expires_at,
      :absolute_expires_at,
      :last_used_at
    ])
    |> validate_absolute_expiry_immutable(value)
  end

  defp validate_absolute_expiry_immutable(
         changeset,
         %__MODULE__{__meta__: %{state: :loaded}, absolute_expires_at: current}
       ) do
    case fetch_change(changeset, :absolute_expires_at) do
      {:ok, ^current} -> changeset
      {:ok, _changed} -> add_error(changeset, :absolute_expires_at, "cannot be changed")
      :error -> changeset
    end
  end

  defp validate_absolute_expiry_immutable(changeset, _session), do: changeset
end
