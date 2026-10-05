defmodule CommsCore.Messaging.PrivateEventReceipt do
  @enforce_keys [:matrix_event_id, :matrix_room_id, :matrix_sender, :content]
  defstruct [:matrix_event_id, :matrix_room_id, :matrix_sender, :content]

  @type t :: %__MODULE__{
          matrix_event_id: String.t(),
          matrix_room_id: String.t(),
          matrix_sender: String.t(),
          content: map()
        }
end
