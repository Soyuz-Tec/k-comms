defmodule CommsCore.AdministrationTenantOwnerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Administration, Repo}
  alias CommsCore.Administration.{Tenant, TenantView}

  test "active tenant queries expose only the stable owner projection" do
    tenant = tenant_fixture(:active)

    assert {:ok, %TenantView{} = by_id} = Administration.active_tenant(tenant.id)
    assert {:ok, %TenantView{} = by_slug} = Administration.active_tenant_by_slug(tenant.slug)

    assert by_id == by_slug
    assert by_id.id == tenant.id
    assert by_id.slug == tenant.slug
    assert by_id.status == :active
    refute function_exported?(by_id.__struct__, :__schema__, 1)
  end

  test "inactive, missing, and malformed tenants are uniformly unavailable" do
    suspended = tenant_fixture(:suspended)
    deleting = tenant_fixture(:deleting)

    for tenant <- [suspended, deleting] do
      assert {:error, :tenant_unavailable} = Administration.active_tenant(tenant.id)

      assert {:error, :tenant_unavailable} =
               Administration.active_tenant_by_slug(tenant.slug)
    end

    assert {:error, :tenant_unavailable} = Administration.active_tenant(Ecto.UUID.generate())
    assert {:error, :tenant_unavailable} = Administration.active_tenant("not-a-uuid")
    assert {:error, :tenant_unavailable} = Administration.active_tenant(nil)

    assert {:error, :tenant_unavailable} =
             Administration.active_tenant_by_slug("missing-tenant")

    assert {:error, :tenant_unavailable} = Administration.active_tenant_by_slug(nil)
  end

  defp tenant_fixture(status) do
    suffix = System.unique_integer([:positive])

    %Tenant{}
    |> Tenant.changeset(%{
      name: "Tenant #{suffix}",
      slug: "tenant-#{suffix}",
      status: status
    })
    |> Repo.insert!()
  end
end
