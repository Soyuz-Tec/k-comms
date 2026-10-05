defmodule CommsCore.AudioCalls.CalendarSync.ProtectionReceipt do
  @moduledoc "Retained Calls-owned governance facts without foreign persistence."
  @enforce_keys [:held?, :capture_blocked?]
  defstruct [:held?, :capture_blocked?]
  @type t :: %__MODULE__{held?: boolean(), capture_blocked?: boolean()}
end
