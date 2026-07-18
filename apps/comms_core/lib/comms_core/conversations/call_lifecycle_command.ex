defmodule CommsCore.Conversations.CallLifecycleCommand do
  @moduledoc """
  Persistence-neutral Conversations command for revoking active call admissions.
  """

  @enforce_keys [:operation, :tenant_id, :conversation_id, :reason]
  defstruct [:operation, :tenant_id, :conversation_id, :user_id, :reason]

  @type operation :: :membership_revoked | :conversation_archived

  @type t :: %__MODULE__{
          operation: operation(),
          tenant_id: binary(),
          conversation_id: binary(),
          user_id: binary() | nil,
          reason: binary()
        }

  @spec membership_revoked(binary(), binary(), binary(), binary()) :: t()
  def membership_revoked(tenant_id, conversation_id, user_id, reason) do
    %__MODULE__{
      operation: :membership_revoked,
      tenant_id: tenant_id,
      conversation_id: conversation_id,
      user_id: user_id,
      reason: reason
    }
  end

  @spec conversation_archived(binary(), binary(), binary()) :: t()
  def conversation_archived(tenant_id, conversation_id, reason) do
    %__MODULE__{
      operation: :conversation_archived,
      tenant_id: tenant_id,
      conversation_id: conversation_id,
      reason: reason
    }
  end
end
