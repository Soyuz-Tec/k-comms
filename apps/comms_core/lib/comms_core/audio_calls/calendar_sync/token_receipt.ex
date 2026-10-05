defmodule CommsCore.AudioCalls.CalendarSync.TokenReceipt do
  @moduledoc "Verified delegated credentials; never a browser or audit projection."
  @derive {Inspect, except: [:access_token, :refresh_token, :identity]}
  @enforce_keys [:provider, :access_token, :expires_at, :scopes]
  defstruct [:provider, :access_token, :refresh_token, :identity, :expires_at, :scopes]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          access_token: binary(),
          refresh_token: binary() | nil,
          identity: CommsCore.AudioCalls.CalendarSync.ExternalIdentityReceipt.t() | nil,
          expires_at: DateTime.t(),
          scopes: [binary()]
        }
end
