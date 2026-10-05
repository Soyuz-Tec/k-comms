defmodule CommsCore.AudioCalls.CalendarSync.SourceContributionQuery do
  @moduledoc "Prepare before Meeting row locks, under the source transaction's Governance seal."
  @enforce_keys [:subject, :meeting_id, :deadline_ms]
  defstruct [:subject, :meeting_id, :deadline_ms]
  @type t :: %__MODULE__{subject: map(), meeting_id: binary(), deadline_ms: integer()}
end
