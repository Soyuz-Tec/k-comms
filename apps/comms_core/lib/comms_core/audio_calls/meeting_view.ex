defmodule CommsCore.AudioCalls.MeetingView do
  @moduledoc "Persistence-neutral scheduled meeting and bounded occurrence projection."
  defstruct [
    :id,
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
    :occurrences,
    :can_manage
  ]

  @type occurrence :: %{
          id: binary(),
          sequence: pos_integer(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          status: :scheduled | :cancelled,
          call_id: binary() | nil
        }
  @type recurrence :: %{frequency: String.t(), interval: pos_integer(), count: pos_integer()}
  @type host_policy :: %{allow_guests: boolean(), join_before_host: boolean()}
  @type t :: %__MODULE__{
          id: binary(),
          conversation_id: binary(),
          host_user_id: binary(),
          title: String.t(),
          timezone: String.t(),
          local_start: NaiveDateTime.t(),
          duration_minutes: pos_integer(),
          recurrence: recurrence(),
          reminder_minutes: non_neg_integer(),
          host_policy: host_policy(),
          status: :scheduled | :cancelled,
          version: pos_integer(),
          occurrences: [occurrence()],
          can_manage: boolean()
        }
end
