defmodule CommsCore.Administration.PrivilegedAuthorizationTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration

  alias CommsCore.{Accounts, Administration, Audit, Governance, Repo}
  alias CommsCore.Accounts.Session
  alias CommsTestSupport.Fixtures

  test "privileged lifecycle, session, and invitation revocations require step-up and a normalized reason" do
    account = Fixtures.account_fixture()
    privileged_subject = Fixtures.step_up(account)

    assert {:ok, managed_user} =
             Accounts.create_user(
               %{
                 display_name: "Reasoned member",
                 email: "reasoned-member@example.test",
                 password: "correct-horse-reasoned-member",
                 role: "member"
               },
               privileged_subject
             )

    assert {:ok, managed_login} =
             Accounts.authenticate_view(
               account.tenant.slug,
               managed_user.email,
               "correct-horse-reasoned-member",
               %{name: "Reasoned member browser", platform: "test"}
             )

    assert {:ok, invitation_result} =
             Administration.create_invitation(
               %{
                 email: "reasoned-invitation@example.test",
                 role: "member",
                 idempotency_key: "reasoned-invitation"
               },
               privileged_subject
             )

    invitation = invitation_result.invitation

    from(session in Session, where: session.id == ^account.session.id)
    |> Repo.update_all(set: [step_up_at: nil])

    subject = Fixtures.subject(account)

    assert {:error, :step_up_required} =
             Accounts.change_user(
               managed_user.id,
               %{version: 1, status: "suspended", reason: "security response"},
               subject
             )

    assert {:error, :step_up_required} =
             Accounts.admin_revoke_session(
               managed_user.id,
               managed_login.session_id,
               %{reason: "security response"},
               subject
             )

    assert {:error, :step_up_required} =
             Administration.revoke_invitation(
               invitation.id,
               %{version: 1, reason: "security response"},
               subject
             )

    subject = Fixtures.step_up(account, subject)

    assert {:error, :reason_required} =
             Accounts.change_user(managed_user.id, %{version: 1, status: "suspended"}, subject)

    assert {:error, :reason_required} =
             Accounts.admin_revoke_session(
               managed_user.id,
               managed_login.session_id,
               %{},
               subject
             )

    assert {:error, :reason_required} =
             Administration.revoke_invitation(invitation.id, %{version: 1}, subject)

    assert {:ok, _session} =
             Accounts.admin_revoke_session(
               managed_user.id,
               managed_login.session_id,
               %{reason: "  revoke compromised browser  "},
               subject
             )

    assert {:ok, _user} =
             Accounts.change_user(
               managed_user.id,
               %{version: 1, status: "suspended", reason: "  suspend compromised account  "},
               subject
             )

    assert {:ok, _invitation} =
             Administration.revoke_invitation(
               invitation.id,
               %{version: 1, reason: "  invitation no longer required  "},
               subject
             )

    assert Audit.get_by!(%{
             tenant_id: account.tenant.id,
             action: "session.admin_revoke"
           }).metadata["reason"] == "revoke compromised browser"

    assert Audit.get_by!(%{
             tenant_id: account.tenant.id,
             action: "user.lifecycle_update",
             resource_id: managed_user.id
           }).metadata["reason"] == "suspend compromised account"

    assert Audit.get_by!(%{
             tenant_id: account.tenant.id,
             action: "invitation.revoke"
           }).metadata["reason"] == "invitation no longer required"
  end

  test "compliance and security authority remain separate from tenant administration" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)

    assert {:ok, admin} =
             Accounts.create_user(
               %{
                 display_name: "Tenant Admin",
                 email: "separated-admin@example.test",
                 password: "correct-horse-separated-admin",
                 role: "admin"
               },
               owner_subject
             )

    assert {:ok, compliance} =
             Accounts.create_user(
               %{
                 display_name: "Compliance Admin",
                 email: "compliance@example.test",
                 password: "correct-horse-compliance-admin",
                 role: "compliance_admin"
               },
               owner_subject
             )

    assert {:ok, security} =
             Accounts.create_user(
               %{
                 display_name: "Security Admin",
                 email: "security@example.test",
                 password: "correct-horse-security-admin",
                 role: "security_admin"
               },
               owner_subject
             )

    admin_subject = login_subject(account, admin, "correct-horse-separated-admin")
    compliance_subject = login_subject(account, compliance, "correct-horse-compliance-admin")
    security_subject = login_subject(account, security, "correct-horse-security-admin")

    assert {:error, :forbidden} = Governance.list_legal_holds(%{}, admin_subject)
    assert {:error, :step_up_required} = Governance.list_legal_holds(%{}, compliance_subject)

    assert {:ok, _} =
             Accounts.step_up(
               %{current_password: "correct-horse-compliance-admin"},
               compliance_subject
             )

    assert {:ok, []} = Governance.list_legal_holds(%{}, compliance_subject)

    assert {:ok, _} =
             Accounts.step_up(
               %{current_password: "correct-horse-security-admin"},
               security_subject
             )

    assert {:error, :forbidden} =
             Accounts.list_user_sessions(account.user.id, security_subject)

    assert {:error, :forbidden} = Governance.list_legal_holds(%{}, security_subject)

    assert Audit.get_by(%{
             tenant_id: account.tenant.id,
             actor_user_id: admin.id,
             action: "authorization.denied"
           })
  end

  defp login_subject(account, user, password) do
    {:ok, login} =
      Accounts.authenticate_view(account.tenant.slug, user.email, password, %{
        name: "Role test browser",
        platform: "test"
      })

    {:ok, access_context} = Accounts.access_context(login.session_id)
    access_context.subject
  end
end
