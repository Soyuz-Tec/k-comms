defmodule CommsCore.Notifications.Intent do
  use CommsCore.Schema

  schema "notification_intents" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:event_type, :string)
    field(:channel, Ecto.Enum, values: [:email, :push, :in_app])
    field(:destination, :string, redact: true)
    belongs_to(:push_subscription, CommsCore.Notifications.PushSubscription)
    field(:push_subscription_version, :integer)
    field(:payload, :map, default: %{})
    field(:idempotency_key, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :delivering, :retryable, :delivered, :failed],
      default: :pending
    )

    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:claimed_at, :utc_datetime_usec)
    field(:claim_generation, :integer, default: 0)
    field(:claim_token, Ecto.UUID)
    field(:delivered_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:read_at, :utc_datetime_usec)
    field(:dismissed_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :event_type,
      :channel,
      :destination,
      :push_subscription_id,
      :push_subscription_version,
      :payload,
      :idempotency_key,
      :status,
      :attempt_count,
      :next_attempt_at,
      :claimed_at,
      :claim_generation,
      :claim_token,
      :delivered_at,
      :last_error_code,
      :read_at,
      :dismissed_at
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :event_type,
      :channel,
      :destination,
      :payload,
      :idempotency_key,
      :status,
      :next_attempt_at
    ])
    |> validate_length(:event_type, min: 1, max: 120)
    |> validate_length(:destination, min: 1, max: 320)
    |> validate_length(:idempotency_key, min: 8, max: 255)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:claim_generation, greater_than_or_equal_to: 0)
    |> validate_number(:push_subscription_version, greater_than: 0)
    |> unique_constraint([:tenant_id, :idempotency_key])
    |> check_constraint(:claim_token, name: :notification_intents_claim_consistent)
    |> check_constraint(:push_subscription_id,
      name: :notification_intents_push_subscription_shape
    )
    |> check_constraint(:read_at, name: :notification_intents_user_state_in_app_only)
    |> check_constraint(:dismissed_at, name: :notification_intents_dismissed_is_read)
    |> foreign_key_constraint(:user_id, name: :notification_intents_tenant_user_id_fk)
    |> foreign_key_constraint(:push_subscription_id)
  end
end
