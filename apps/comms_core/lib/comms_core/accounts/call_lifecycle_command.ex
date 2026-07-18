defmodule CommsCore.Accounts.CallLifecycleCommand do
  @moduledoc """
  Persistence-neutral IdentityAccess command for revoking active call admissions.
  """

  @enforce_keys [:operation, :tenant_id, :reason]
  defstruct [:operation, :tenant_id, :session_ids, :device_id, :user_id, :reason]

  @type operation :: :sessions_revoked | :device_revoked | :user_access_revoked

  @type t :: %__MODULE__{
          operation: operation(),
          tenant_id: binary(),
          session_ids: [binary()] | nil,
          device_id: binary() | nil,
          user_id: binary() | nil,
          reason: binary()
        }

  @spec sessions_revoked(binary(), [binary()], binary()) :: t()
  def sessions_revoked(tenant_id, session_ids, reason) do
    %__MODULE__{
      operation: :sessions_revoked,
      tenant_id: tenant_id,
      session_ids: session_ids,
      reason: reason
    }
  end

  @spec device_revoked(binary(), binary(), binary()) :: t()
  def device_revoked(tenant_id, device_id, reason) do
    %__MODULE__{
      operation: :device_revoked,
      tenant_id: tenant_id,
      device_id: device_id,
      reason: reason
    }
  end

  @spec user_access_revoked(binary(), binary(), binary()) :: t()
  def user_access_revoked(tenant_id, user_id, reason) do
    %__MODULE__{
      operation: :user_access_revoked,
      tenant_id: tenant_id,
      user_id: user_id,
      reason: reason
    }
  end
end
