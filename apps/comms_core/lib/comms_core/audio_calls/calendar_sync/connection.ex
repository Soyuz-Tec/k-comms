defmodule CommsCore.AudioCalls.CalendarSync.Connection do
  @moduledoc false
  use CommsCore.Schema

  schema "calendar_connections" do
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:provider, Ecto.Enum, values: [:google, :microsoft])

    field(:status, Ecto.Enum,
      values: [
        :awaiting_consent,
        :ready,
        :reauthorization_required,
        :removing,
        :held_cleanup_blocked,
        :removed
      ],
      default: :awaiting_consent
    )

    field(:version, :integer, default: 1)
    field(:consent_generation, :integer, default: 1)
    field(:credential_generation, :integer, default: 1)
    field(:export_policy_version, :integer)
    field(:credentials_box, :map, redact: true)
    field(:external_identity_box, :map, redact: true)
    field(:access_expires_at, :utc_datetime_usec)
    field(:fenced_at, :utc_datetime_usec)
    field(:credential_destroyed_at, :utc_datetime_usec)

    field(:provider_grant_revocation, Ecto.Enum,
      values: [:not_requested, :pending, :confirmed, :external_unconfirmed, :failed],
      default: :not_requested
    )

    field(:last_success_at, :utc_datetime_usec)
    field(:safe_reason, :string)
    timestamps()
  end
end
