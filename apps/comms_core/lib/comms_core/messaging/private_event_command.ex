defmodule CommsCore.Messaging.PrivateEventCommand do
  @moduledoc "ConversationContent-owned authenticated opaque send. Client credential belongs to the exact retained K-session; no server crypto keys."
  @enforce_keys [:grant, :client_session, :transaction_id, :content]
  defstruct [:grant, :client_session, :transaction_id, :content]

  @type t :: %__MODULE__{
          grant: CommsCore.Conversations.PrivateRoomGrant.t(),
          client_session: CommsCore.Accounts.MatrixClientSessionView.t(),
          transaction_id: String.t(),
          content: map()
        }
end
