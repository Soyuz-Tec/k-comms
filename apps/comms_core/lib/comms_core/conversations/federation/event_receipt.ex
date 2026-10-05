defmodule CommsCore.Conversations.Federation.EventReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Inspect, only: [:id, :tenant_id]}
  schema "federation_event_receipts" do
    field(:tenant_id, :binary_id)
    field(:room_id, :binary_id)
    field(:command_id, :binary_id)
    field(:event_hash, :string)
    field(:provider_event_box, :binary)
    field(:sender_hash, :string)
    field(:observed_at, :utc_datetime_usec)
    field(:redacted_observed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs),
    do:
      record
      |> cast(attrs, [
        :tenant_id,
        :room_id,
        :command_id,
        :event_hash,
        :provider_event_box,
        :sender_hash,
        :observed_at,
        :redacted_observed_at
      ])
      |> validate_required([:tenant_id])
end
