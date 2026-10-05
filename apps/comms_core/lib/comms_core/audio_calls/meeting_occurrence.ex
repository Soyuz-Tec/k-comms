defmodule CommsCore.AudioCalls.MeetingOccurrence do
  @moduledoc false
  use CommsCore.Schema

  schema "meeting_occurrences" do
    field(:tenant_id, :binary_id)
    field(:meeting_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:call_id, :binary_id)
    field(:sequence, :integer)
    field(:meeting_version, :integer)
    field(:starts_at, :utc_datetime_usec)
    field(:ends_at, :utc_datetime_usec)
    field(:reminder_at, :utc_datetime_usec)
    field(:reminder_sent_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:scheduled, :cancelled], default: :scheduled)
    timestamps()
  end

  def changeset(occurrence, attrs) do
    occurrence
    |> cast(attrs, [
      :tenant_id,
      :meeting_id,
      :conversation_id,
      :call_id,
      :sequence,
      :meeting_version,
      :starts_at,
      :ends_at,
      :reminder_at,
      :reminder_sent_at,
      :status
    ])
    |> validate_required([
      :tenant_id,
      :meeting_id,
      :conversation_id,
      :sequence,
      :meeting_version,
      :starts_at,
      :ends_at,
      :reminder_at,
      :status
    ])
    |> unique_constraint([:meeting_id, :meeting_version, :sequence])
    |> unique_constraint(:call_id)
    |> check_constraint(:ends_at, name: :meeting_occurrences_bounded_duration)
  end
end
