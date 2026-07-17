defmodule CommsCore.Integrations.WebhookDelivery do
  use CommsCore.Schema

  schema "webhook_deliveries" do
    field(:tenant_id, :binary_id)
    belongs_to(:endpoint, CommsCore.Integrations.WebhookEndpoint)
    belongs_to(:outbox_event, CommsCore.Events.OutboxEvent)
    field(:event_type, :string)
    field(:payload, :map, default: %{})
    field(:idempotency_key, :string)
    field(:secret_version, :integer)

    field(:status, Ecto.Enum,
      values: [:pending, :delivering, :retryable, :delivered, :failed],
      default: :pending
    )

    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:claimed_at, :utc_datetime_usec)
    field(:claim_generation, :integer, default: 0)
    field(:claim_token, Ecto.UUID)
    field(:last_attempt_at, :utc_datetime_usec)
    field(:delivered_at, :utc_datetime_usec)
    field(:response_status, :integer)
    field(:last_error_code, :string)
    timestamps()
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :tenant_id,
      :endpoint_id,
      :outbox_event_id,
      :event_type,
      :payload,
      :idempotency_key,
      :secret_version,
      :status,
      :attempt_count,
      :next_attempt_at,
      :claimed_at,
      :claim_generation,
      :claim_token,
      :last_attempt_at,
      :delivered_at,
      :response_status,
      :last_error_code
    ])
    |> validate_required([
      :tenant_id,
      :endpoint_id,
      :event_type,
      :payload,
      :idempotency_key,
      :secret_version,
      :status,
      :next_attempt_at
    ])
    |> validate_length(:event_type, min: 1, max: 120)
    |> validate_length(:idempotency_key, min: 8, max: 255)
    |> validate_number(:secret_version, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:claim_generation, greater_than_or_equal_to: 0)
    |> unique_constraint([:tenant_id, :idempotency_key])
    |> check_constraint(:claim_token, name: :webhook_deliveries_claim_consistent)
    |> foreign_key_constraint(:endpoint_id,
      name: :webhook_deliveries_tenant_endpoint_id_fk
    )
    |> foreign_key_constraint(:outbox_event_id,
      name: :webhook_deliveries_tenant_outbox_event_id_fk
    )
  end
end
