defmodule CommsCore.Notifications.AttemptView do
  @moduledoc "Stable notification-delivery attempt contract."

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t() | nil,
          intent_id: Ecto.UUID.t() | nil,
          attempt_number: pos_integer() | nil,
          provider: String.t() | nil,
          status: atom() | nil,
          http_status: integer() | nil,
          error_code: String.t() | nil,
          provider_message_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :tenant_id,
    :intent_id,
    :attempt_number,
    :provider,
    :status,
    :http_status,
    :error_code,
    :provider_message_id,
    :started_at,
    :completed_at,
    :inserted_at
  ]
end
