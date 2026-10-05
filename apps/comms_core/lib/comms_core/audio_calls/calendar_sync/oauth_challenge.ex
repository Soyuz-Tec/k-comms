defmodule CommsCore.AudioCalls.CalendarSync.OAuthChallenge do
  @moduledoc false
  use CommsCore.Schema

  schema "calendar_oauth_challenges" do
    field(:tenant_id, :binary_id)
    field(:connection_id, :binary_id)
    field(:user_id, :binary_id)
    field(:device_id, :binary_id)
    field(:session_id, :binary_id)
    field(:provider, Ecto.Enum, values: [:google, :microsoft])
    field(:state_hash, :binary, redact: true)
    field(:binding_hash, :binary, redact: true)
    field(:challenge_box, :map, redact: true)
    field(:consent_generation, :integer)
    field(:export_policy_version, :integer)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:terminal_reason, :string)
    timestamps()
  end
end
