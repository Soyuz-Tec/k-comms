defmodule CommsCore.AudioCalls.CalendarSync.ExternalIdentityReceipt do
  @moduledoc "Fixed-provider signed identity; email is deliberately absent."
  @derive {Inspect, except: [:external_subject, :oidc_subject]}
  @enforce_keys [:provider, :external_subject, :oidc_subject]
  defstruct [:provider, :external_subject, :oidc_subject]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          external_subject: binary(),
          oidc_subject: binary()
        }
end
