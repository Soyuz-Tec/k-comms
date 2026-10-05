defmodule CommsCore.Accounts.RoleCapabilityView do
  @moduledoc "Fixed-role eligibility and the conditions still required by the owning operation."
  @enforce_keys [:capability, :scope, :conditions]
  defstruct [:capability, :scope, :conditions]

  @type capability ::
          :administer_users
          | :manage_user_lifecycle
          | :manage_sessions
          | :manage_tenant_settings
          | :manage_invitations
          | :audit_tenant
          | :govern_tenant
  @type condition ::
          :active_tenant
          | :active_identity
          | :current_session
          | :recent_step_up
          | :workspace_access
  @type t :: %__MODULE__{capability: capability(), scope: :tenant, conditions: [condition()]}
end
