defmodule CommsCore.AudioCalls.CalendarSync.EventMapping do
  @moduledoc false
  use CommsCore.Schema

  schema "calendar_event_mappings" do
    field(:tenant_id, :binary_id)
    field(:connection_id, :binary_id)
    field(:export_id, :binary_id)
    field(:meeting_id, :binary_id)
    field(:occurrence_sequence, :integer)
    field(:consent_generation, :integer)
    field(:sync_generation, :integer)
    field(:desired_meeting_version, :integer)
    field(:applied_meeting_version, :integer)

    field(:status, Ecto.Enum,
      values: [:unknown, :present, :absent, :conflict, :removing],
      default: :unknown
    )

    field(:external_identity_box, :map, redact: true)
    field(:etag_box, :map, redact: true)
    field(:duplicate_identities_box, :map, redact: true)
    field(:tombstoned_at, :utc_datetime_usec)
    field(:verified_at, :utc_datetime_usec)
    timestamps()
  end
end
