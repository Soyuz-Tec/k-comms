defmodule CommsCore.AudioCalls.CalendarSync.IdentityFenceReceipt do
  @moduledoc "Local export fencing; this is never an external removal proof."
  @enforce_keys [:fenced_connection_count, :pending_cleanup_command_count]
  defstruct [:fenced_connection_count, :pending_cleanup_command_count]

  @type t :: %__MODULE__{
          fenced_connection_count: non_neg_integer(),
          pending_cleanup_command_count: non_neg_integer()
        }
end
