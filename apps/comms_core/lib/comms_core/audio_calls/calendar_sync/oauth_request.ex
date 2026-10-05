defmodule CommsCore.AudioCalls.CalendarSync.OAuthRequest do
  @moduledoc "A calendar-owned, already authorized delegated token request."
  @derive {Inspect, except: [:code, :verifier, :refresh_token, :nonce]}
  @enforce_keys [:provider, :operation, :deadline_ms]
  defstruct [:provider, :operation, :deadline_ms, :code, :verifier, :refresh_token, :nonce]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          operation: :exchange | :refresh,
          deadline_ms: integer(),
          code: binary() | nil,
          verifier: binary() | nil,
          refresh_token: binary() | nil,
          nonce: binary() | nil
        }
end
