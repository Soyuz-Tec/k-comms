defmodule CommsCore.Conversations.AdmissionUsage do
  @moduledoc """
  Ecto-free conversation-capacity projection for cross-context read models.
  """

  @enforce_keys [:active_conversations, :largest_conversation_members]
  defstruct [:active_conversations, :largest_conversation_members]

  @type t :: %__MODULE__{
          active_conversations: non_neg_integer(),
          largest_conversation_members: non_neg_integer()
        }
end
