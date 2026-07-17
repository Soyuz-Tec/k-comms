defmodule CommsCore.Messaging.RetentionScope do
  @moduledoc """
  Persistence-neutral retention cutoff for one conversation.

  TrustGovernance supplies the policy decision; ConversationContent owns the
  query that applies it to messages.
  """

  @enforce_keys [:conversation_id, :cutoff_at]
  defstruct [:conversation_id, :cutoff_at]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          cutoff_at: DateTime.t()
        }
end
