defmodule CommsCore.AudioCalls.CalendarSync.ErasureReceipt do
  @moduledoc false
  use CommsCore.Schema

  schema "calendar_erasure_receipts" do
    field(:tenant_id, :binary_id)
    field(:target_type, Ecto.Enum, values: [:user, :conversation, :message])
    field(:target_fingerprint, :binary)
    field(:version, :integer, default: 1)
    field(:status, Ecto.Enum, values: [:pending, :held, :verified], default: :pending)
    field(:removed_event_count, :integer, default: 0)
    field(:destroyed_credential_count, :integer, default: 0)
    field(:verified_at, :utc_datetime_usec)
    timestamps()
  end
end
