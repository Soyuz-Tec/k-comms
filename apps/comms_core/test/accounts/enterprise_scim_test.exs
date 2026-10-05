defmodule CommsCore.Accounts.EnterpriseScimTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Repo, ServiceAccounts}
  alias CommsCore.Accounts.{FederatedIdentity, User}
  alias CommsTestSupport.Fixtures
  @password "enterprise-directory-password-1234"

  setup do
    owner = Fixtures.account_fixture(%{password: @password})
    subject = Fixtures.subject(owner)
    {:ok, _} = Accounts.step_up_view(%{current_password: @password}, subject)

    {:ok, credential} =
      ServiceAccounts.create_view(
        %{
          name: "Corporate directory",
          scopes: ["scim:read", "scim:write"],
          reason: "Provision synthetic enterprise identities"
        },
        subject
      )

    {:ok, service} = ServiceAccounts.authenticate(credential.credential)
    %{owner: owner, subject: subject, credential: credential, service: service}
  end

  test "SCIM is idempotent, scoped, and cannot assign authority", %{
    owner: owner,
    service: service
  } do
    attrs = %{
      "externalId" => "directory-001",
      "userName" => "corporate-user@example.test",
      "displayName" => "Corporate user",
      "active" => true
    }

    {:ok, user} = Accounts.scim_create("User", attrs, service)
    {:ok, duplicate} = Accounts.scim_create("User", attrs, service)
    assert user.id == duplicate.id
    row = Repo.get_by!(User, tenant_id: owner.tenant.id, email: attrs["userName"])
    assert row.role == :member
    assert is_nil(row.password_hash)

    assert {:error, :scim_group_authority_denied} =
             Accounts.scim_create("User", Map.put(attrs, "roles", ["owner"]), service)

    other = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             Accounts.scim_get("User", user.id, Map.put(service, :tenant_id, other.tenant.id))

    # Even a guessed id cannot cross a tenant through group membership.
    assert {:error, :invalid_scim_member} =
             Accounts.scim_create(
               "Group",
               %{
                 "externalId" => "group",
                 "displayName" => "Team",
                 "members" => [%{"value" => other.user.id}]
               },
               service
             )

    {:ok, group} =
      Accounts.scim_create(
        "Group",
        %{"externalId" => "group", "displayName" => "Team", "members" => [%{"value" => user.id}]},
        service
      )

    assert group.members == [%{value: user.id}]
    assert Repo.get!(User, row.id).role == :member
    refute Repo.exists?(FederatedIdentity)
  end

  test "malformed lifecycle documents fail without partial provisioning or version changes", %{
    service: service
  } do
    attrs = %{
      "externalId" => "malformed-input",
      "userName" => "malformed@example.test",
      "displayName" => "Managed"
    }

    for changes <- [
          %{"name" => "bad", "displayName" => nil},
          %{"active" => "false"},
          %{"urn:kcomms:params:scim:schemas:extension:federation:2.0:User" => "bad"}
        ] do
      assert {:error, :invalid_scim_resource} =
               Accounts.scim_create("User", Map.merge(attrs, changes), service)
    end

    refute Repo.get_by(User, email: attrs["userName"])
    {:ok, resource} = Accounts.scim_create("User", attrs, service)

    for document <- [
          %{"schemas" => "bad", "Operations" => [%{"op" => "replace"}]},
          %{
            "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
            "Operations" => [nil]
          },
          %{
            "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
            "Operations" => [%{"op" => %{}}]
          }
        ] do
      assert {:error, :invalid_scim_patch} =
               Accounts.scim_patch("User", resource.id, document, resource.meta.version, service)
    end

    {:ok, unchanged} = Accounts.scim_get("User", resource.id, service)
    assert unchanged.meta.version == resource.meta.version
  end

  test "suspension revokes sessions, challenges, and stale directory writes", %{
    service: service,
    owner: owner
  } do
    {:ok, resource} =
      Accounts.scim_create(
        "User",
        %{
          "externalId" => "managed",
          "userName" => "managed@example.test",
          "displayName" => "Managed"
        },
        service
      )

    user = Repo.get_by!(User, tenant_id: owner.tenant.id, email: resource.userName)

    user =
      Repo.update!(
        Ecto.Changeset.change(user, password_hash: CommsCore.Security.Password.hash(@password))
      )

    {:ok, auth} = Accounts.password_sign_in(owner.tenant.slug, user.email, @password, %{})

    {:ok, suspended} =
      Accounts.scim_patch(
        "User",
        resource.id,
        %{
          "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
          "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
        },
        resource.meta.version,
        service
      )

    refute suspended.active
    assert {:error, :invalid_refresh_token} = Accounts.refresh_session_view(auth.refresh_token)
    assert {:error, :session_expired} = Accounts.access_context(auth.session_id)

    assert {:error, :stale_version} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"active" => true},
               resource.meta.version,
               service
             )

    assert {:error, :email_change_requires_verification} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"userName" => "attacker@example.test"},
               suspended.meta.version,
               service
             )

    assert {:error, :scim_group_authority_denied} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"role" => "owner"},
               suspended.meta.version,
               service
             )
  end

  test "SCIM cannot suspend the last owner and rotated service credentials stop immediately", %{
    service: service,
    owner: owner,
    credential: credential,
    subject: subject
  } do
    {:ok, resource} =
      Accounts.scim_create(
        "User",
        %{
          "externalId" => "owner-managed",
          "userName" => "managed-owner@example.test",
          "displayName" => "Managed owner"
        },
        service
      )

    managed = Repo.get_by!(User, email: resource.userName, tenant_id: owner.tenant.id)
    Repo.update!(Ecto.Changeset.change(managed, role: :owner))
    Repo.update!(Ecto.Changeset.change(owner.user, role: :member))

    assert {:error, :last_owner_required} =
             Accounts.scim_delete("User", resource.id, resource.meta.version, service)

    Repo.update!(Ecto.Changeset.change(Repo.get!(User, owner.user.id), role: :owner))

    {:ok, _} =
      ServiceAccounts.rotate_view(
        credential.service_account.id,
        %{version: credential.service_account.version, reason: "Rotate directory credential"},
        subject
      )

    assert {:error, :forbidden} = Accounts.scim_list("User", %{}, service)
    assert {:error, :invalid_service_token} = ServiceAccounts.authenticate(credential.credential)
  end
end
