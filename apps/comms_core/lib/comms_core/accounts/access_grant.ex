defmodule CommsCore.Accounts.AccessGrant do
  @moduledoc """
  Persistence-free authorization facts verified by IdentityAccess.

  Callers receive identity and access facts without depending on the Accounts
  Ecto schemas. Platform authority is usable only when
  `platform_claim_verified?` is true; this binds a session subject to the exact
  persisted grant generation, role, and expiry.
  """

  @enforce_keys [
    :tenant_id,
    :user_id,
    :device_id,
    :session_id,
    :role,
    :step_up_recent?,
    :platform_claim_verified?
  ]

  defstruct [
    :tenant_id,
    :user_id,
    :device_id,
    :session_id,
    :request_id,
    :role,
    :step_up_at,
    :platform_role_grant_id,
    :platform_role,
    :platform_role_expires_at,
    :step_up_recent?,
    :platform_claim_verified?
  ]

  @type tenant_role ::
          :member | :moderator | :admin | :compliance_admin | :security_admin | :owner

  @type platform_role :: :platform_operator | :support_operator | :security_operator

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          user_id: String.t(),
          device_id: String.t(),
          session_id: String.t(),
          request_id: String.t() | nil,
          role: tenant_role(),
          step_up_at: DateTime.t() | nil,
          step_up_recent?: boolean(),
          platform_role_grant_id: String.t() | nil,
          platform_role: platform_role() | nil,
          platform_role_expires_at: DateTime.t() | nil,
          platform_claim_verified?: boolean()
        }
end
