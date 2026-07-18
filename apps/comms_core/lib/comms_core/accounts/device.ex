defmodule CommsCore.Accounts.Device do
  use CommsCore.Schema

  schema "devices" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:user, CommsCore.Accounts.User)
    field(:name, :string)
    field(:platform, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :name,
      :platform,
      :last_seen_at,
      :revoked_at
    ])
    |> validate_required([:tenant_id, :user_id, :name, :platform])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:platform, min: 1, max: 40)
  end
end
