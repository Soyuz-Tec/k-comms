defmodule CommsCore.Accounts.UserLifecycleTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Audit, Repo, ValidationError}
  alias CommsCore.Accounts.User
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  test "governed lifecycle contribution requires a transaction and validated owner exclusions" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    attrs = %{version: account.user.lock_version, display_name: "Governed owner"}

    assert {:error, :transaction_required} =
             Accounts.apply_user_lifecycle_change(account.user.id, attrs, subject, [])

    assert {:ok, {:error, :invalid_owner_exclusions}} =
             Repo.transaction(fn ->
               Accounts.apply_user_lifecycle_change(
                 account.user.id,
                 attrs,
                 subject,
                 ["not-a-user-id"]
               )
             end)
  end

  test "governed lifecycle returns a persistence-free validation error and rolls back" do
    account = Fixtures.account_fixture()
    managed_user = Fixtures.user_fixture(account).user
    subject = Fixtures.step_up(account)

    assert {:error, %ValidationError{details: %{display_name: messages}}} =
             Repo.transaction(fn ->
               Accounts.apply_user_lifecycle_change(
                 managed_user.id,
                 %{
                   version: managed_user.lock_version,
                   display_name: "",
                   reason: "reject an invalid lifecycle update"
                 },
                 subject,
                 []
               )
             end)

    assert "can't be blank" in messages
    assert Repo.get!(User, managed_user.id).display_name == managed_user.display_name

    assert Audit.count(%{
             tenant_id: account.tenant.id,
             action: "user.lifecycle_update",
             resource_id: managed_user.id
           }) == 0
  end

  test "owners and admins create tenant-scoped users with audit evidence" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)
    admin_password = "correct-horse-admin-password"

    assert {:ok, admin} =
             Accounts.create_user(
               %{
                 tenant_id: Ecto.UUID.generate(),
                 display_name: "Workspace Admin",
                 email: "workspace-admin@example.test",
                 password: admin_password,
                 role: "admin"
               },
               owner_subject
             )

    assert admin.tenant_id == account.tenant.id
    assert admin.role == :admin
    assert Password.verify(admin_password, admin.password_hash)

    assert {:ok, admin_login} =
             Accounts.authenticate_view(
               account.tenant.slug,
               admin.email,
               admin_password,
               %{name: "Admin browser", platform: "test"}
             )

    assert {:ok, %{subject: admin_subject}} = Accounts.access_context(admin_login.session_id)

    assert {:ok, _session} =
             Accounts.step_up(%{current_password: admin_password}, admin_subject)

    assert {:ok, member} =
             Accounts.create_user(
               %{
                 display_name: "Workspace Member",
                 email: "workspace-member@example.test",
                 password: "correct-horse-member-password"
               },
               admin_subject
             )

    assert member.tenant_id == account.tenant.id
    assert member.role == :member

    assert 2 == Audit.count(%{tenant_id: account.tenant.id, action: "user.create"})
  end
end
