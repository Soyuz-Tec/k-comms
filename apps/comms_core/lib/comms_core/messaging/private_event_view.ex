defmodule CommsCore.Messaging.PrivateEventView do
  @moduledoc "Opaque ciphertext receipt with trusted provider sender attribution. No plaintext or client author assertions are accepted."
  @enforce_keys [
    :id,
    :conversation_id,
    :sequence,
    :matrix_event_id,
    :matrix_room_id,
    :matrix_sender,
    :author_user_id,
    :membership_epoch,
    :generation,
    :content,
    :state
  ]
  defstruct [
    :id,
    :conversation_id,
    :sequence,
    :matrix_event_id,
    :matrix_room_id,
    :matrix_sender,
    :author_user_id,
    :membership_epoch,
    :generation,
    :content,
    :state
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          conversation_id: String.t(),
          sequence: pos_integer(),
          matrix_event_id: String.t() | nil,
          matrix_room_id: String.t(),
          matrix_sender: String.t(),
          author_user_id: String.t(),
          membership_epoch: pos_integer(),
          generation: pos_integer(),
          content: map() | nil,
          state: :pending | :retained | :erased
        }
end
