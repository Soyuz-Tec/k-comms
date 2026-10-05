defmodule CommsCore.AudioCalls.ArtifactProtection do
  @moduledoc "Calls-owned governance projection for artifact retention and legal holds."
  @enforce_keys [:held, :retention_days]
  defstruct [:held, :retention_days, capture_blocked: false]

  @type t :: %__MODULE__{
          held: boolean(),
          retention_days: pos_integer(),
          capture_blocked: boolean()
        }
end
