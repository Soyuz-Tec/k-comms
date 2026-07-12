defmodule CommsCore.Events.OutboxEvent do
  use CommsCore.Schema

  schema "outbox_events" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    field(:event_type, :string)
    field(:aggregate_type, :string)
    field(:aggregate_id, :binary_id)
    field(:payload, :map)
    field(:available_at, :utc_datetime_usec)
    field(:published_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    timestamps(updated_at: false)
  end

  def changeset(value, attrs),
    do:
      value
      |> cast(attrs, [
        :tenant_id,
        :event_type,
        :aggregate_type,
        :aggregate_id,
        :payload,
        :available_at,
        :published_at,
        :attempts
      ])
      |> validate_required([
        :tenant_id,
        :event_type,
        :aggregate_type,
        :aggregate_id,
        :payload,
        :available_at
      ])
end
