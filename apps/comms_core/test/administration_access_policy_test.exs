defmodule CommsCore.AdministrationAccessPolicyTest do
  use ExUnit.Case, async: true

  alias CommsCore.Administration.{AccessPolicy, IdentityGrant}

  test "tenant access decisions are pure, named, and role-scoped" do
    assert :ok = AccessPolicy.authorize(:read_capabilities, grant(:member, false))

    for role <- [:owner, :admin] do
      assert :ok = AccessPolicy.authorize(:administer_tenant, grant(role, false))
    end

    assert {:error, :forbidden} =
             AccessPolicy.authorize(:administer_tenant, grant(:moderator, true))
  end

  test "step-up policies reject roles before evaluating recency" do
    for permission <- [:manage_invitations, :manage_tenant_settings] do
      assert :ok = AccessPolicy.authorize(permission, grant(:admin, true))

      assert {:error, :step_up_required} =
               AccessPolicy.authorize(permission, grant(:admin, false))

      assert {:error, :forbidden} =
               AccessPolicy.authorize(permission, grant(:member, false))
    end
  end

  test "audit access is limited to stepped-up governance roles" do
    for role <- [:owner, :compliance_admin, :security_admin] do
      assert :ok = AccessPolicy.authorize(:audit_tenant, grant(role, true))
    end

    assert {:error, :step_up_required} =
             AccessPolicy.authorize(:audit_tenant, grant(:compliance_admin, false))

    assert {:error, :forbidden} =
             AccessPolicy.authorize(:audit_tenant, grant(:admin, true))

    assert {:error, :forbidden} =
             AccessPolicy.authorize(:unknown_permission, grant(:owner, true))
  end

  defp grant(role, step_up_recent?) do
    %IdentityGrant{
      tenant_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      role: role,
      step_up_recent?: step_up_recent?
    }
  end
end
