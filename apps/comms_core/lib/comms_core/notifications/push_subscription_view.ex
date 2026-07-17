defmodule CommsCore.Notifications.PushSubscriptionView do
  @moduledoc "Stable, non-secret browser-push subscription contract."

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          device_id: Ecto.UUID.t() | nil,
          endpoint_hint: String.t() | nil,
          version: pos_integer() | nil,
          status: atom() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          stale_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :tenant_id,
    :user_id,
    :device_id,
    :endpoint_hint,
    :version,
    :status,
    :expires_at,
    :revoked_at,
    :stale_at,
    :inserted_at,
    :updated_at
  ]
end
