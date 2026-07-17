defmodule CommsCore.Conversations.MessageWriteSlot do
  @moduledoc """
  Transaction-scoped grant for persisting one message in a conversation.

  The Conversations context owns sequence reservation. Callers receive only the
  identifiers and sequence needed to persist content, never the conversation
  persistence schema.
  """

  @enforce_keys [:id, :tenant_id, :sequence]
  defstruct [:id, :tenant_id, :sequence]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          sequence: pos_integer()
        }
end
