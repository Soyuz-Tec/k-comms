defmodule CommsCore.AudioCalls.CalendarSync.Export do
  @moduledoc false
  use CommsCore.Schema

  schema "calendar_exports" do
    field(:tenant_id, :binary_id)
    field(:connection_id, :binary_id)
    field(:user_id, :binary_id)
    field(:meeting_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:consent_generation, :integer)
    field(:sync_generation, :integer, default: 1)
    field(:version, :integer, default: 1)
    field(:desired_meeting_version, :integer)
    field(:applied_meeting_version, :integer)

    field(:status, Ecto.Enum,
      values: [:pending, :synced, :conflict, :stopping, :removed, :blocked, :failed, :uncertain],
      default: :pending
    )

    field(:safe_reason, :string)
    field(:author_user_ids, {:array, :binary_id}, default: [])
    field(:author_lineage_complete, :boolean, default: false)
    field(:tombstoned_at, :utc_datetime_usec)
    field(:removed_at, :utc_datetime_usec)
    timestamps()
  end
end
