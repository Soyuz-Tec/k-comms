defmodule CommsCore.Notifications.IntentView do
  @moduledoc "Stable, redacted notification-intent contract for callers outside NotificationDelivery."

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          event_type: String.t() | nil,
          channel: atom() | nil,
          destination_hint: String.t() | nil,
          payload: map(),
          status: atom() | nil,
          attempt_count: non_neg_integer(),
          next_attempt_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          last_error_code: String.t() | nil,
          read_at: DateTime.t() | nil,
          dismissed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :tenant_id,
    :user_id,
    :event_type,
    :channel,
    :destination_hint,
    :status,
    :next_attempt_at,
    :delivered_at,
    :last_error_code,
    :read_at,
    :dismissed_at,
    :inserted_at,
    :updated_at,
    payload: %{},
    attempt_count: 0
  ]
end
