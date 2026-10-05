defmodule CommsCore.AudioCalls.CalendarSync.ConnectionView do
  @moduledoc "Safe calendar status; credentials and external identifiers are absent."
  @enforce_keys [
    :id,
    :provider,
    :version,
    :status,
    :consent_generation,
    :new_exports_allowed?,
    :permission_status,
    :provider_grant_revocation,
    :managed_events_pending_removal
  ]
  defstruct [
    :id,
    :provider,
    :version,
    :status,
    :consent_generation,
    :new_exports_allowed?,
    :permission_status,
    :provider_grant_revocation,
    :managed_events_pending_removal,
    :last_success_at,
    :safe_reason
  ]

  @type t :: %__MODULE__{
          id: binary(),
          provider: :google | :microsoft,
          version: pos_integer(),
          status: atom(),
          consent_generation: pos_integer(),
          new_exports_allowed?: boolean(),
          permission_status: :unverified | :scopes_verified | :verified,
          provider_grant_revocation: atom(),
          managed_events_pending_removal: non_neg_integer(),
          last_success_at: DateTime.t() | nil,
          safe_reason: binary() | nil
        }
end
