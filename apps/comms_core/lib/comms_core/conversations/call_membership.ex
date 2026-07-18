defmodule CommsCore.Conversations.CallMembership do
  @moduledoc """
  Ecto-free active-membership projection used by Calls authorization.
  """

  @enforce_keys [:tenant_id, :conversation_id, :user_id, :role]
  defstruct [:tenant_id, :conversation_id, :user_id, :role]

  @type role :: :member | :moderator | :owner

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          role: role()
        }
end
