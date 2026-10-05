defmodule CommsCore.AudioCalls.CalendarSync.ErasurePlan do
  @moduledoc "Calendar-owned cleanup contribution; local fencing never establishes remote completion."
  @enforce_keys [:pending_export_count, :pending_connection_count]
  defstruct [:pending_export_count, :pending_connection_count]

  @type t :: %__MODULE__{
          pending_export_count: non_neg_integer(),
          pending_connection_count: non_neg_integer()
        }
end
