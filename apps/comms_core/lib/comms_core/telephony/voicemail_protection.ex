defmodule CommsCore.Telephony.VoicemailProtection do
  @moduledoc "Transaction-scoped governance projection for a telephone mailbox."
  @enforce_keys [:held, :retention_days]
  defstruct [:held, :retention_days, capture_blocked: false]

  @type t :: %__MODULE__{
          held: boolean(),
          retention_days: pos_integer(),
          capture_blocked: boolean()
        }
end
