defmodule CommsCore.Accounts.NotificationCommand do
  @moduledoc """
  Persistence-neutral command for IdentityAccess-owned notification effects.

  IdentityAccess supplies only identifiers and delivery data required by the
  requested effect. NotificationDelivery remains responsible for its own
  persistence models and implementation details.
  """

  @derive {Inspect, except: [:destination]}
  @enforce_keys [:operation, :tenant_id, :user_id]
  defstruct [
    :operation,
    :tenant_id,
    :user_id,
    :device_id,
    :session_ids,
    :destination,
    :recovery_request_id,
    :reason
  ]

  @type operation ::
          :password_recovery
          | :device_revoked
          | :user_access_revoked
          | :sessions_revoked
          | :user_erased

  @type t :: %__MODULE__{
          operation: operation(),
          tenant_id: binary(),
          user_id: binary() | nil,
          device_id: binary() | nil,
          session_ids: [binary()] | nil,
          destination: binary() | nil,
          recovery_request_id: binary() | nil,
          reason: binary() | nil
        }

  @spec password_recovery(binary(), binary(), binary(), binary()) :: t()
  def password_recovery(tenant_id, user_id, destination, recovery_request_id) do
    %__MODULE__{
      operation: :password_recovery,
      tenant_id: tenant_id,
      user_id: user_id,
      destination: destination,
      recovery_request_id: recovery_request_id
    }
  end

  @spec device_revoked(binary(), binary(), binary(), binary()) :: t()
  def device_revoked(tenant_id, user_id, device_id, reason \\ "device_revoked") do
    %__MODULE__{
      operation: :device_revoked,
      tenant_id: tenant_id,
      user_id: user_id,
      device_id: device_id,
      reason: reason
    }
  end

  @spec user_access_revoked(binary(), binary(), binary()) :: t()
  def user_access_revoked(tenant_id, user_id, reason \\ "user_revoked") do
    %__MODULE__{
      operation: :user_access_revoked,
      tenant_id: tenant_id,
      user_id: user_id,
      reason: reason
    }
  end

  @spec sessions_revoked(binary(), [binary()], binary()) :: t()
  def sessions_revoked(tenant_id, session_ids, reason) do
    %__MODULE__{
      operation: :sessions_revoked,
      tenant_id: tenant_id,
      user_id: nil,
      session_ids: session_ids,
      reason: reason
    }
  end

  @spec user_erased(binary(), binary()) :: t()
  def user_erased(tenant_id, user_id) do
    %__MODULE__{
      operation: :user_erased,
      tenant_id: tenant_id,
      user_id: user_id,
      reason: "governance_user_erasure"
    }
  end
end
