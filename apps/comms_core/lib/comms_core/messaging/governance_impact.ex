defmodule CommsCore.Messaging.GovernanceImpact do
  @moduledoc """
  Persistence-neutral content identifiers affected by a governance target.

  `found?` reports whether the ConversationContent owner found at least one
  matching message row. Foreign target existence remains the responsibility of
  the context that owns that target.
  """

  @enforce_keys [:found?, :message_ids, :conversation_ids, :user_ids]
  defstruct [:found?, :message_ids, :conversation_ids, :user_ids]

  @type t :: %__MODULE__{
          found?: boolean(),
          message_ids: [String.t()],
          conversation_ids: [String.t()],
          user_ids: [String.t()]
        }
end
