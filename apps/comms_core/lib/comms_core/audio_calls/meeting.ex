defmodule CommsCore.AudioCalls.Meeting do
  @moduledoc false
  use CommsCore.Schema

  schema "meetings" do
    field(:tenant_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:host_user_id, :binary_id)
    field(:title, :string)
    field(:timezone, :string)
    field(:local_start, :naive_datetime)
    field(:duration_minutes, :integer)
    field(:recurrence, :map)
    field(:reminder_minutes, :integer)
    field(:host_policy, :map)
    field(:status, Ecto.Enum, values: [:scheduled, :cancelled], default: :scheduled)
    field(:version, :integer, default: 1)
    field(:author_user_ids, {:array, :binary_id}, default: [])
    field(:author_lineage_complete, :boolean, default: false)
    field(:erasure_requested_at, :utc_datetime_usec)
    field(:erased_at, :utc_datetime_usec)
    field(:erasure_user_fingerprint, :binary)
    timestamps()
  end

  def changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :host_user_id,
      :title,
      :timezone,
      :local_start,
      :duration_minutes,
      :recurrence,
      :reminder_minutes,
      :host_policy,
      :status,
      :version,
      :author_user_ids,
      :author_lineage_complete
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :host_user_id,
      :title,
      :timezone,
      :local_start,
      :duration_minutes,
      :recurrence,
      :reminder_minutes,
      :host_policy,
      :status,
      :version
    ])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_number(:duration_minutes, greater_than_or_equal_to: 5, less_than_or_equal_to: 480)
    |> validate_number(:reminder_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10_080
    )
    |> check_constraint(:duration_minutes, name: :meetings_bounded_duration)
  end
end
