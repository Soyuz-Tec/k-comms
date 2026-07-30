defmodule CommsCore.Administration.IdentityLifecycleIntegrationTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration

  alias CommsCore.{Accounts, Governance, Repo}
  alias CommsTestSupport.Fixtures

  test "user lifecycle uses versions and preserves an active owner" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:error, :governance_policy_required} =
             Accounts.change_user(
               account.user.id,
               %{version: 1, status: "suspended", reason: "owner safety test"},
               subject
             )

    assert {:error, :last_owner_required} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{version: 1, status: "suspended", reason: "owner safety test"},
               subject
             )

    assert {:ok, second_owner} =
             Accounts.create_user(
               %{
                 display_name: "Second owner",
                 email: "second-owner@example.test",
                 password: "correct-horse-second-owner",
                 role: "admin"
               },
               subject
             )

    assert {:ok, promoted} =
             Accounts.change_user(
               second_owner.id,
               %{version: 1, role: "owner", reason: "establish second owner"},
               subject
             )

    assert promoted.role == :owner
    assert promoted.lock_version == 2

    assert {:error, :stale_version} =
             Accounts.change_user(
               promoted.id,
               %{version: 1, status: "suspended", reason: "stale lifecycle test"},
               subject
             )

    assert {:ok, %{user: demoted}} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{version: 1, role: "admin", reason: "transfer tenant ownership"},
               subject
             )

    assert demoted.role == :admin
    assert Repo.get!(CommsCore.Accounts.User, promoted.id).status == :active

    assert {:ok, managed_member} =
             Accounts.create_user(
               %{
                 display_name: "Managed member",
                 email: "managed-member@example.test",
                 password: "correct-horse-managed-member",
                 role: "member"
               },
               subject
             )

    assert {:ok, managed_login} =
             Accounts.authenticate_view(
               account.tenant.slug,
               managed_member.email,
               "correct-horse-managed-member",
               %{name: "Managed browser", platform: "test"}
             )

    assert {:ok, effects} =
             Accounts.change_user_with_effects(
               managed_member.id,
               %{
                 version: managed_member.lock_version,
                 status: "suspended",
                 reason: "suspend compromised account"
               },
               subject
             )

    assert managed_login.session_id in effects.revoked_session_ids
    assert {:error, :session_expired} = Accounts.get_active_session(managed_login.session_id)
  end
end
