defmodule CommsCore.Messaging.RetentionCandidate do
  @moduledoc """
  Persistence-neutral message identity selected for retention processing.
  """

  @enforce_keys [:message_id, :conversation_id]
  defstruct [:message_id, :conversation_id]

  @type t :: %__MODULE__{
          message_id: String.t(),
          conversation_id: String.t()
        }
end
