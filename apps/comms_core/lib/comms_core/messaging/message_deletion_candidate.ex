defmodule CommsCore.Messaging.MessageDeletionCandidate do
  @moduledoc """
  Persistence-neutral message identity used while Governance evaluates deletion policy.

  The struct is produced and consumed inside one caller-owned transaction; it
  deliberately carries only the fields required to evaluate legal holds.
  """

  @enforce_keys [:id, :tenant_id, :conversation_id, :sender_user_id]
  defstruct [:id, :tenant_id, :conversation_id, :sender_user_id]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          sender_user_id: Ecto.UUID.t()
        }
end
