defmodule CommsCore.AudioCalls.MeetingErasurePlan do
  @moduledoc "Calls-owned receipt for transaction-scoped meeting metadata erasure."
  @enforce_keys [:pending_meeting_count, :scrubbed_meeting_count]
  defstruct [:pending_meeting_count, :scrubbed_meeting_count]

  @type t :: %__MODULE__{
          pending_meeting_count: non_neg_integer(),
          scrubbed_meeting_count: non_neg_integer()
        }
end
