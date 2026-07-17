defmodule CommsCore.Notifications.PreferenceView do
  @moduledoc "Stable user notification-preference contract."

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          email_enabled: boolean(),
          push_enabled: boolean(),
          in_app_enabled: boolean(),
          muted_event_types: [String.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :tenant_id,
    :user_id,
    :inserted_at,
    :updated_at,
    email_enabled: true,
    push_enabled: false,
    in_app_enabled: true,
    muted_event_types: []
  ]
end
