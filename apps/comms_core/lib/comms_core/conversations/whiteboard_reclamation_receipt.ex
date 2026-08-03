defmodule CommsCore.Conversations.WhiteboardReclamationReceipt do
  @moduledoc """
  Persistence-neutral receipt for a Collaboration whiteboard-reclamation
  contribution to an instant-room expiry transaction.
  """

  @enforce_keys [:whiteboards_deleted, :whiteboard_operations_deleted]
  defstruct [:whiteboards_deleted, :whiteboard_operations_deleted]

  @type t :: %__MODULE__{
          whiteboards_deleted: non_neg_integer(),
          whiteboard_operations_deleted: non_neg_integer()
        }
end
