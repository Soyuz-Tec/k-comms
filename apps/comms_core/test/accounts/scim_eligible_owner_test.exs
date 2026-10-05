defmodule CommsCore.Accounts.ScimEligibleOwnerTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Governance, Repo, ServiceAccounts}
  alias CommsCore.Accounts.{ScimResource, User}
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  test "SCIM cannot deactivate or delete the only workspace owner while a legacy limited owner remains" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, credential} =
             ServiceAccounts.create_view(
               %{
                 name: "Eligible owner SCIM policy",
                 scopes: ["scim:read", "scim:write"],
                 reason: "Exercise current tenant owner preservation"
               },
               subject
             )

    assert {:ok, service} = ServiceAccounts.authenticate(credential.credential)

    assert {:ok, resource} =
             Accounts.scim_create(
               "User",
               %{
                 "externalId" => "eligible-owner-" <> account.user.id,
                 "userName" => "eligible-owner-#{account.user.id}@example.test",
                 "displayName" => "Managed workspace owner"
               },
               service
             )

    managed = Repo.get_by!(User, tenant_id: account.tenant.id, email: resource.userName)

    assert {:ok, %{user: %{role: :owner}}} =
             Governance.change_user_lifecycle_view(
               managed.id,
               %{
                 role: :owner,
                 version: managed.lock_version,
                 reason: "Assign actual managed workspace owner"
               },
               subject
             )

    legacy =
      Fixtures.user_fixture(account, %{role: :owner}).user
      |> Ecto.Changeset.change(access_scope: :conversation_only)
      |> Repo.update!()

    assert Repo.get!(User, legacy.id).access_scope == :conversation_only

    assert {:ok, %{user: %{role: :member}}} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{
                 role: :member,
                 version: account.user.lock_version,
                 reason: "Retain managed workspace owner"
               },
               subject
             )

    current = Repo.get!(User, managed.id)

    assert current.role == :owner and current.status == :active and
             current.access_scope == :workspace

    assert {:error, :last_owner_required} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"active" => false},
               resource.meta.version,
               service
             )

    assert {:error, :last_owner_required} =
             Accounts.scim_delete("User", resource.id, resource.meta.version, service)

    assert Repo.get!(User, managed.id).status == :active
    assert Repo.get!(User, managed.id).lock_version == current.lock_version
    assert Repo.get!(ScimResource, resource.id).lock_version == 1
    assert Repo.get!(User, legacy.id).role == :owner
    assert Repo.get!(User, legacy.id).access_scope == :conversation_only
    assert Repo.get!(User, account.user.id).role == :member

    successor = Fixtures.user_fixture(account, %{role: :owner, access_scope: :workspace}).user

    assert {:ok, updated} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"active" => false},
               resource.meta.version,
               service
             )

    assert updated.meta.version != resource.meta.version
    assert Repo.get!(User, managed.id).status == :suspended
    assert Repo.get!(User, successor.id).status == :active
    assert Repo.get!(User, successor.id).access_scope == :workspace
  end

  test "SCIM can clean up an unusable legacy limited owner without an eligible workspace owner" do
    account = Fixtures.account_fixture()

    assert {:ok, credential} =
             ServiceAccounts.create_view(
               %{
                 name: "Legacy owner cleanup",
                 scopes: ["scim:read", "scim:write"],
                 reason: "Exercise safe cleanup of scoped predecessor identities"
               },
               Fixtures.step_up(account)
             )

    assert {:ok, service} = ServiceAccounts.authenticate(credential.credential)

    assert {:ok, resource} =
             Accounts.scim_create(
               "User",
               %{
                 "externalId" => "legacy-owner-" <> account.user.id,
                 "userName" => "legacy-owner-#{account.user.id}@example.test",
                 "displayName" => "Legacy scoped owner"
               },
               service
             )

    managed = Repo.get_by!(User, tenant_id: account.tenant.id, email: resource.userName)

    # Reproduce a predecessor state that current governed role mutation refuses.
    managed =
      managed
      |> Ecto.Changeset.change(role: :owner, access_scope: :conversation_only)
      |> Repo.update!()

    account.user |> Ecto.Changeset.change(role: :member) |> Repo.update!()

    assert Repo.aggregate(
             from(user in User,
               where:
                 user.tenant_id == ^account.tenant.id and user.role == :owner and
                   user.status == :active and user.account_type == :human and
                   user.access_scope == :workspace
             ),
             :count
           ) == 0

    assert {:ok, suspended} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"active" => false},
               resource.meta.version,
               service
             )

    assert Repo.get!(User, managed.id).status == :suspended

    assert {:ok, restored} =
             Accounts.scim_replace(
               "User",
               resource.id,
               %{"active" => true},
               suspended.meta.version,
               service
             )

    assert {:ok, _receipt} =
             Accounts.scim_delete("User", resource.id, restored.meta.version, service)

    assert Repo.get!(User, managed.id).status == :suspended
    assert Repo.get!(User, managed.id).access_scope == :conversation_only
  end
end
