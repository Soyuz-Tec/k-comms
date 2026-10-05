defmodule CommsCore.Messaging.PrivateEventIntentView do
  @moduledoc "Exact current-session pending ciphertext intent. Other participants never receive a sender's transaction identifiers."
  @enforce_keys [:transaction_id, :content, :membership_epoch, :generation]
  defstruct [:transaction_id, :content, :membership_epoch, :generation]

  @type t :: %__MODULE__{
          transaction_id: String.t(),
          content: map(),
          membership_epoch: pos_integer(),
          generation: pos_integer()
        }
end
