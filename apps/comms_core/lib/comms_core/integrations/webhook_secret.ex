defmodule CommsCore.Integrations.WebhookSecret do
  use CommsCore.Schema

  schema "webhook_secret_versions" do
    field(:tenant_id, :binary_id)
    belongs_to(:endpoint, CommsCore.Integrations.WebhookEndpoint)
    field(:version, :integer)
    field(:ciphertext, :binary, redact: true)
    field(:nonce, :binary, redact: true)
    field(:tag, :binary, redact: true)
    field(:key_id, :string)
    field(:retired_at, :utc_datetime_usec)
    timestamps(updated_at: false)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [
      :tenant_id,
      :endpoint_id,
      :version,
      :ciphertext,
      :nonce,
      :tag,
      :key_id,
      :retired_at
    ])
    |> validate_required([:tenant_id, :endpoint_id, :version, :ciphertext, :nonce, :tag, :key_id])
    |> validate_number(:version, greater_than: 0)
    |> validate_format(:key_id, ~r/^[A-Za-z0-9_.-]{1,64}$/)
    |> validate_binary_size(:ciphertext, min: 1)
    |> validate_binary_size(:nonce, exact: 12)
    |> validate_binary_size(:tag, exact: 16)
    |> unique_constraint([:endpoint_id, :version])
    |> check_constraint(:nonce, name: :webhook_secret_versions_crypto_shape)
    |> check_constraint(:key_id, name: :webhook_secret_versions_context_bound_key)
    |> foreign_key_constraint(:endpoint_id,
      name: :webhook_secret_versions_tenant_endpoint_id_fk
    )
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
