defmodule CommsCore.Notifications.PushSubscription do
  use CommsCore.Schema

  schema "push_subscriptions" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:device_id, Ecto.UUID)
    field(:endpoint_hash, :binary, redact: true)
    field(:endpoint_hint, :string)
    field(:version, :integer, default: 1)
    field(:ciphertext, :binary, redact: true)
    field(:nonce, :binary, redact: true)
    field(:tag, :binary, redact: true)
    field(:key_id, :string)
    field(:status, Ecto.Enum, values: [:active, :revoked, :expired, :stale], default: :active)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:stale_at, :utc_datetime_usec)
    field(:last_materialized_at, :utc_datetime_usec)
    field(:disabled_reason, :string)
    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :device_id,
      :endpoint_hash,
      :endpoint_hint,
      :version,
      :ciphertext,
      :nonce,
      :tag,
      :key_id,
      :status,
      :expires_at,
      :revoked_at,
      :stale_at,
      :last_materialized_at,
      :disabled_reason
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :device_id,
      :endpoint_hash,
      :endpoint_hint,
      :version,
      :ciphertext,
      :nonce,
      :tag,
      :key_id,
      :status
    ])
    |> validate_length(:endpoint_hint, min: 1, max: 255)
    |> validate_length(:disabled_reason, max: 120)
    |> validate_number(:version, greater_than: 0)
    |> validate_format(:key_id, ~r/^[A-Za-z0-9_.-]{1,64}$/)
    |> validate_binary_size(:endpoint_hash, exact: 32)
    |> validate_binary_size(:ciphertext, min: 1)
    |> validate_binary_size(:nonce, exact: 12)
    |> validate_binary_size(:tag, exact: 16)
    |> unique_constraint(:endpoint_hash, name: :push_subscriptions_endpoint_hash_unique)
    |> check_constraint(:version, name: :push_subscriptions_version_positive)
    |> check_constraint(:endpoint_hash, name: :push_subscriptions_endpoint_hash_shape)
    |> check_constraint(:nonce, name: :push_subscriptions_crypto_shape)
    |> check_constraint(:status, name: :push_subscriptions_status_allowed)
    |> foreign_key_constraint(:user_id, name: :push_subscriptions_tenant_user_id_fk)
    |> foreign_key_constraint(:device_id, name: :push_subscriptions_tenant_user_device_id_fk)
  end

  defp validate_binary_size(changeset, field, opts) do
    validate_change(changeset, field, fn ^field, value ->
      valid? =
        is_binary(value) and
          case opts do
            [exact: size] -> byte_size(value) == size
            [min: size] -> byte_size(value) >= size
          end

      if valid?, do: [], else: [{field, "has an invalid byte length"}]
    end)
  end
end
