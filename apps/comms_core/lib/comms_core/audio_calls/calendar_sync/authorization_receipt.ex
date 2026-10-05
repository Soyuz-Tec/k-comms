defmodule CommsCore.AudioCalls.CalendarSync.AuthorizationReceipt do
  @moduledoc "One-use delegated consent URL and a server-cookie-only binding."
  @derive {Inspect, except: [:authorization_url, :browser_binding]}
  @enforce_keys [:provider, :authorization_url, :browser_binding, :expires_at]
  defstruct [:provider, :authorization_url, :browser_binding, :expires_at]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          authorization_url: binary(),
          browser_binding: binary(),
          expires_at: DateTime.t()
        }
end
