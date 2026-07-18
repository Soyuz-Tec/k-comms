defmodule CommsCore.Integrations.WebhookSubscription do
  use CommsCore.Schema

  schema "webhook_subscriptions" do
    field(:tenant_id, :binary_id)
    field(:endpoint_id, :binary_id)
    field(:event_type, :string)
    timestamps(updated_at: false)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:tenant_id, :endpoint_id, :event_type])
    |> validate_required([:tenant_id, :endpoint_id, :event_type])
    |> validate_length(:event_type, min: 1, max: 120)
    |> unique_constraint([:endpoint_id, :event_type])
    |> foreign_key_constraint(:endpoint_id,
      name: :webhook_subscriptions_tenant_endpoint_id_fk
    )
  end
end
