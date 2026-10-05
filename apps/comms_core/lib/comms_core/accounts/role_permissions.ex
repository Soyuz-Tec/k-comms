defmodule CommsCore.Accounts.RolePermissions do
  @moduledoc false
  alias CommsCore.Accounts.{FixedRolePermissionView, RoleCapabilityView}

  @roles [:member, :moderator, :admin, :compliance_admin, :security_admin, :owner]
  @elevated [:owner, :admin, :compliance_admin, :security_admin]
  # These are existing role eligibility facts, not an authorization dispatcher.
  # Actual owner facade tests pin their conditions and all six roles.
  @capabilities [
    {:administer_users, [:owner, :admin], false, true},
    {:manage_user_lifecycle, [:owner, :admin], true, true},
    {:manage_sessions, [:owner, :security_admin], true, true},
    {:manage_tenant_settings, [:owner, :admin], true, true},
    {:manage_invitations, [:owner, :admin], true, true},
    {:audit_tenant, [:owner, :compliance_admin, :security_admin], true, true},
    {:govern_tenant, [:owner, :compliance_admin], true, true}
  ]

  def roles, do: @roles
  def normalize_role(value) when value in @roles, do: {:ok, value}

  def normalize_role(value) when is_binary(value) do
    case Enum.find(@roles, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_role}
      role -> {:ok, role}
    end
  end

  def normalize_role(_), do: {:error, :invalid_role}

  def authorize_change(_actor_role, _current_role, requested_role, :conversation_only)
      when requested_role in @elevated,
      do: {:error, :forbidden}

  def authorize_change(:owner, _current_role, _requested_role, _target_scope), do: :ok

  def authorize_change(:admin, current_role, requested_role, _target_scope) do
    if current_role in @elevated or requested_role in @elevated,
      do: {:error, :forbidden},
      else: :ok
  end

  def authorize_change(_, _, _, _), do: {:error, :forbidden}

  def authorize_creation(actor_role, role)
      when role in [:member, :moderator, :admin, :compliance_admin, :security_admin] do
    if actor_role == :owner or (actor_role == :admin and role in [:member, :moderator]),
      do: :ok,
      else: {:error, :forbidden}
  end

  def authorize_creation(_, _), do: {:error, :invalid_role}

  def catalog do
    Enum.map(
      @roles,
      &%FixedRolePermissionView{role: &1, capabilities: capabilities(&1, :workspace)}
    )
  end

  def capabilities(role, access_scope) do
    for {capability, allowed, step_up?, workspace?} <- @capabilities,
        role in allowed,
        not workspace? or access_scope == :workspace do
      conditions =
        [:active_tenant, :active_identity, :current_session] ++
          if(step_up?, do: [:recent_step_up], else: []) ++
          if workspace?, do: [:workspace_access], else: []

      %RoleCapabilityView{capability: capability, scope: :tenant, conditions: conditions}
    end
  end
end
