defmodule CommsCore.Conversations.CallConversation do
  @moduledoc """
  Ecto-free conversation identity returned to the Calls transaction coordinator.
  """

  @enforce_keys [:id, :tenant_id]
  defstruct [:id, :tenant_id]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t()
        }
end
