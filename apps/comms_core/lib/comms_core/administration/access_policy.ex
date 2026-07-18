defmodule CommsCore.Administration.AccessPolicy do
  @moduledoc false

  alias CommsCore.Administration.IdentityGrant

  @type permission ::
          :read_capabilities
          | :administer_tenant
          | :manage_invitations
          | :manage_tenant_settings
          | :audit_tenant

  @type denial :: :forbidden | :step_up_required

  @spec authorize(permission(), IdentityGrant.t()) :: :ok | {:error, denial()}
  def authorize(:read_capabilities, %IdentityGrant{}), do: :ok

  def authorize(:administer_tenant, %IdentityGrant{} = grant),
    do: authorize_roles(grant, [:owner, :admin], false)

  def authorize(:manage_invitations, %IdentityGrant{} = grant),
    do: authorize_roles(grant, [:owner, :admin], true)

  def authorize(:manage_tenant_settings, %IdentityGrant{} = grant),
    do: authorize_roles(grant, [:owner, :admin], true)

  def authorize(:audit_tenant, %IdentityGrant{} = grant),
    do: authorize_roles(grant, [:owner, :compliance_admin, :security_admin], true)

  def authorize(_permission, _grant), do: {:error, :forbidden}

  defp authorize_roles(grant, roles, step_up_required?) do
    cond do
      grant.role not in roles -> {:error, :forbidden}
      step_up_required? and not grant.step_up_recent? -> {:error, :step_up_required}
      true -> :ok
    end
  end
end
