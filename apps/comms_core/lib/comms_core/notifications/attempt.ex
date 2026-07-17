defmodule CommsCore.Notifications.Attempt do
  use CommsCore.Schema

  schema "notification_attempts" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:intent, CommsCore.Notifications.Intent)
    field(:attempt_number, :integer)
    field(:provider, :string)
    field(:status, Ecto.Enum, values: [:delivered, :retryable, :failed])
    field(:http_status, :integer)
    field(:error_code, :string)
    field(:provider_message_id, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    timestamps(updated_at: false)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :tenant_id,
      :intent_id,
      :attempt_number,
      :provider,
      :status,
      :http_status,
      :error_code,
      :provider_message_id,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :tenant_id,
      :intent_id,
      :attempt_number,
      :provider,
      :status,
      :started_at,
      :completed_at
    ])
    |> validate_number(:attempt_number, greater_than: 0)
    |> unique_constraint([:intent_id, :attempt_number])
    |> foreign_key_constraint(:intent_id, name: :notification_attempts_tenant_intent_id_fk)
  end
end
