defmodule CommsCore.Notifications.NativePushRegistration do
  use CommsCore.Schema
  schema "native_push_registrations" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:device_id, Ecto.UUID)
    field(:session_id, Ecto.UUID)
    field(:installation_id, Ecto.UUID)
    field(:user_version, :integer)
    field(:platform, :string)
    field(:channel, :string)
    field(:application_id, :string)
    field(:environment, :string)
    field(:version, :integer, default: 1)
    field(:token_hash, :binary, redact: true)
    field(:ciphertext, :binary, redact: true)
    field(:nonce, :binary, redact: true)
    field(:tag, :binary, redact: true)
    field(:key_id, :string)
    field(:status, :string, default: "active")
    field(:expires_at, :utc_datetime_usec)
    field(:disabled_at, :utc_datetime_usec)
    timestamps()
  end
  def changeset(row, attrs) do
    row |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:tenant_id, :user_id, :device_id, :session_id, :installation_id,
                          :user_version, :platform, :channel, :application_id, :environment,
                          :version, :token_hash, :status, :expires_at])
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:user_version, greater_than: 0)
    |> validate_inclusion(:status, ["active", "revoked", "expired", "stale"])
    |> unique_constraint([:platform, :channel, :application_id, :environment, :token_hash],
                         name: :native_push_token_unique)
    |> unique_constraint([:tenant_id, :user_id, :device_id, :channel], name: :native_push_device_channel_unique)
  end
end
