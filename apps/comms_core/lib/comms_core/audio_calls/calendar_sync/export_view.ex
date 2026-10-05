defmodule CommsCore.AudioCalls.CalendarSync.ExportView do
  @moduledoc "Opaque one-way export status without provider identifiers or credentials."
  @enforce_keys [
    :id,
    :connection_id,
    :meeting_id,
    :version,
    :status,
    :desired_meeting_version,
    :applied_meeting_version,
    :occurrence_count,
    :safe_reason
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: binary(),
          connection_id: binary(),
          meeting_id: binary(),
          version: pos_integer(),
          status: atom(),
          desired_meeting_version: pos_integer(),
          applied_meeting_version: pos_integer() | nil,
          occurrence_count: non_neg_integer(),
          safe_reason: binary() | nil
        }
end
