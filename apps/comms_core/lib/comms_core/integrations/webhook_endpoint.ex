defmodule CommsCore.Integrations.WebhookEndpoint do
  use CommsCore.Schema

  schema "webhook_endpoints" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:created_by_user, CommsCore.Accounts.User)
    field(:name, :string)
    field(:url, :string)
    field(:status, Ecto.Enum, values: [:active, :disabled], default: :active)
    field(:secret_version, :integer, default: 1)
    field(:disabled_at, :utc_datetime_usec)

    has_many(:subscriptions, CommsCore.Integrations.WebhookSubscription,
      foreign_key: :endpoint_id
    )

    has_many(:deliveries, CommsCore.Integrations.WebhookDelivery, foreign_key: :endpoint_id)
    timestamps()
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [
      :tenant_id,
      :created_by_user_id,
      :name,
      :url,
      :status,
      :secret_version,
      :disabled_at
    ])
    |> validate_required([:tenant_id, :created_by_user_id, :name, :url, :status, :secret_version])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:url, min: 1, max: 2_048)
    |> validate_number(:secret_version, greater_than: 0)
    |> validate_https_url(:url)
    |> unique_constraint([:tenant_id, :name])
    |> foreign_key_constraint(:created_by_user_id,
      name: :webhook_endpoints_tenant_created_by_user_id_fk
    )
  end

  defp validate_https_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      uri = URI.parse(value)

      if uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
           is_nil(uri.fragment) do
        []
      else
        [{field, "must be an HTTPS URL without credentials or fragments"}]
      end
    end)
  end
end
