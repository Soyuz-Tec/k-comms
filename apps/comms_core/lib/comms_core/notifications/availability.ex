defmodule CommsCore.Notifications.Availability do
  @moduledoc "Content-free signal emitted when a user's in-app notification state changes."

  @type t :: %__MODULE__{
          notification_id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          event_type: String.t(),
          conversation_id: Ecto.UUID.t() | nil,
          message_id: Ecto.UUID.t() | nil
        }

  defstruct [
    :notification_id,
    :tenant_id,
    :user_id,
    :event_type,
    :conversation_id,
    :message_id
  ]
end
