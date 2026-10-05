defmodule CommsCore.AudioCalls.CalendarSync.SyncCommand do
  @moduledoc false
  use CommsCore.Schema

  schema "calendar_sync_commands" do
    field(:tenant_id, :binary_id)
    field(:connection_id, :binary_id)
    field(:export_id, :binary_id)
    field(:mapping_id, :binary_id)

    field(:operation, Ecto.Enum,
      values: [
        :create,
        :update,
        :delete,
        :verify_absence,
        :reconcile,
        :refresh,
        :revoke,
        :destroy
      ]
    )

    field(:consent_generation, :integer)
    field(:credential_generation, :integer)
    field(:sync_generation, :integer)
    field(:meeting_version, :integer)

    field(:status, Ecto.Enum,
      values: [:queued, :leased, :uncertain, :retryable, :blocked, :done, :failed],
      default: :queued
    )

    field(:attempt, :integer, default: 0)
    field(:lease_id, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:available_at, :utc_datetime_usec)
    field(:safe_reason, :string)
    field(:completed_at, :utc_datetime_usec)
    timestamps()
  end
end
