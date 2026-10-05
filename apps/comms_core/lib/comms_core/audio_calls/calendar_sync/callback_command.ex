defmodule CommsCore.AudioCalls.CalendarSync.CallbackCommand do
  @moduledoc "Browser-bound calendar callback, never a sign-in command."
  @derive {Inspect, except: [:state, :code, :browser_binding]}
  @enforce_keys [:provider, :state, :code, :browser_binding]
  defstruct [:provider, :state, :code, :browser_binding]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          state: binary(),
          code: binary(),
          browser_binding: binary()
        }
end
