defmodule CommsCore.AudioCalls.CalendarSync.ProviderCapability do
  @moduledoc "Configured and provider-qualified are distinct calendar facts."
  @enforce_keys [:provider, :configured?]
  defstruct [:provider, :configured?, :safe_reason, qualified?: false]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          configured?: boolean(),
          qualified?: boolean(),
          safe_reason: atom() | nil
        }
end
