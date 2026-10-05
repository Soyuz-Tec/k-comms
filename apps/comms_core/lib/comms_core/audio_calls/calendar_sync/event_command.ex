defmodule CommsCore.AudioCalls.CalendarSync.EventCommand do
  @moduledoc "A persisted, opaque managed-calendar effect with one absolute network budget."
  @derive {Inspect, except: [:access_token, :external_id, :title, :etag, :identity]}
  @enforce_keys [:provider, :operation, :marker_id, :access_token, :deadline_ms, :identity]
  defstruct [
    :provider,
    :operation,
    :marker_id,
    :access_token,
    :deadline_ms,
    :identity,
    :external_id,
    :etag,
    :title,
    :starts_at,
    :ends_at,
    :timezone,
    :authenticated_url
  ]

  @type t :: %__MODULE__{
          provider: :google | :microsoft,
          operation: :create | :update | :delete | :get | :reconcile,
          marker_id: binary(),
          access_token: binary(),
          deadline_ms: integer(),
          identity: CommsCore.AudioCalls.CalendarSync.ExternalIdentityReceipt.t(),
          external_id: binary() | nil,
          etag: binary() | nil,
          title: binary() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          timezone: binary() | nil,
          authenticated_url: binary() | nil
        }
end
