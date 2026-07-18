defmodule CommsCore.Administration.IdentityGrant do
  @moduledoc """
  TenantAdministration-owned identity facts used by tenant policy decisions.

  The contract is Ecto-free and deliberately omits session, device, and
  platform-role persistence details.
  """

  @enforce_keys [:tenant_id, :user_id, :role, :step_up_recent?]
  defstruct [:tenant_id, :user_id, :role, :step_up_recent?]

  @type role ::
          :owner
          | :admin
          | :moderator
          | :member
          | :compliance_admin
          | :security_admin

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          role: role(),
          step_up_recent?: boolean()
        }
end
