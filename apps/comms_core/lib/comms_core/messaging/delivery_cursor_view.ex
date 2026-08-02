defmodule CommsCore.Messaging.DeliveryCursorView do
  @moduledoc "Persistence-neutral per-device delivery cursor exposed to conversation members."

  @enforce_keys [
    :recipient_user_id,
    :device_ref,
    :delivered_sequence,
    :read_sequence
  ]
  defstruct [
    :recipient_user_id,
    :device_ref,
    :delivered_sequence,
    :read_sequence,
    :delivered_at,
    :read_at
  ]

  @type t :: %__MODULE__{
          recipient_user_id: Ecto.UUID.t(),
          device_ref: String.t(),
          delivered_sequence: non_neg_integer(),
          read_sequence: non_neg_integer(),
          delivered_at: DateTime.t() | nil,
          read_at: DateTime.t() | nil
        }
end
