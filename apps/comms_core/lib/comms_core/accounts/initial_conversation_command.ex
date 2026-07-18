defmodule CommsCore.Accounts.InitialConversationCommand do
  @moduledoc """
  Persistence-neutral command for creating the initial tenant conversation.

  IdentityAccess supplies only identifiers and the join timestamp required by
  the Conversations owner. The command contains no Conversation or Membership
  persistence model.
  """

  @enforce_keys [:id, :tenant_id, :owner_user_id, :joined_at]
  defstruct [:id, :tenant_id, :owner_user_id, :joined_at]

  @type t :: %__MODULE__{
          id: binary(),
          tenant_id: binary(),
          owner_user_id: binary(),
          joined_at: DateTime.t()
        }
end
