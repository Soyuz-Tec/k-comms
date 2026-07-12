defmodule CommsCore.AccountsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{Session, Tenant, User}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Authorization
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Repo
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

  test "bootstraps a tenant and authenticates its owner" do
    account = Fixtures.account_fixture()

    assert account.tenant.status == :active
    assert account.user.role == :owner
    assert account.conversation.title == "General"
    assert is_binary(account.refresh_token)

    assert {:ok, authenticated} =
             Accounts.authenticate(
               account.tenant.slug,
               account.user.email,
               account_fixture_password(account),
               %{name: "Second browser", platform: "test"}
             )

    assert authenticated.user.id == account.user.id
    assert authenticated.device.user_id == account.user.id
    assert {:ok, refreshed} = Accounts.refresh_session(authenticated.refresh_token)
    assert refreshed.session.id == authenticated.session.id
    assert refreshed.refresh_token != authenticated.refresh_token
  end

  test "one-time release bootstrap is sessionless and idempotent" do
    attrs = release_bootstrap_attrs()

    assert {:ok, created} = Accounts.bootstrap_tenant_once(attrs)
    assert created.status == :created
    assert created.tenant.slug == attrs.tenant_slug
    assert created.user.email == attrs.email
    assert created.user.role == :owner
    assert created.conversation.title == "General"

    assert Repo.aggregate(Tenant, :count) == 1
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(Conversation, :count) == 1
    assert Repo.aggregate(Membership, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 1
    assert Repo.aggregate(Session, :count) == 0

    assert {:ok, existing} = Accounts.bootstrap_tenant_once(attrs)
    assert existing.status == :existing
    assert existing.tenant.id == created.tenant.id
    assert existing.user.id == created.user.id
    assert existing.conversation.id == created.conversation.id

    assert Repo.aggregate(Tenant, :count) == 1
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(Conversation, :count) == 1
    assert Repo.aggregate(Membership, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 1
    assert Repo.aggregate(Session, :count) == 0

    assert {:ok, authenticated} =
             Accounts.authenticate(attrs.tenant_slug, attrs.email, attrs.password)

    assert authenticated.user.id == created.user.id
  end

  test "one-time release bootstrap rejects a different identity" do
    attrs = release_bootstrap_attrs()
    assert {:ok, %{status: :created}} = Accounts.bootstrap_tenant_once(attrs)

    assert {:error, :bootstrap_identity_conflict} =
             Accounts.bootstrap_tenant_once(%{
               attrs
               | tenant_slug: "another-workspace",
                 email: "another-owner@example.test"
             })

    assert {:error, :bootstrap_identity_conflict} =
             Accounts.bootstrap_tenant_once(%{attrs | email: "another-owner@example.test"})

    assert Repo.aggregate(Tenant, :count) == 1
    assert Repo.aggregate(User, :count) == 1
  end

  test "explicit local-proof bootstrap grants a platform role once with audit evidence" do
    restore_allow = preserve_env(:allow_bootstrap_platform_role)
    restore_role = preserve_env(:bootstrap_platform_role)

    on_exit(fn ->
      restore_allow.()
      restore_role.()
    end)

    Application.put_env(:comms_core, :allow_bootstrap_platform_role, true)
    Application.put_env(:comms_core, :bootstrap_platform_role, "platform_operator")

    attrs = release_bootstrap_attrs()
    assert {:ok, created} = Accounts.bootstrap_tenant_once(attrs)
    assert created.user.platform_role == :platform_operator

    assert Repo.aggregate(
             from(event in AuditEvent,
               where:
                 event.tenant_id == ^created.tenant.id and
                   event.action == "platform_role.bootstrap_grant"
             ),
             :count
           ) == 1

    assert {:ok, existing} = Accounts.bootstrap_tenant_once(attrs)
    assert existing.user.platform_role == :platform_operator

    assert Repo.aggregate(
             from(event in AuditEvent,
               where:
                 event.tenant_id == ^created.tenant.id and
                   event.action == "platform_role.bootstrap_grant"
             ),
             :count
           ) == 1
  end

  test "platform roles require the audited console boundary and propagate into session subjects" do
    restore_secret = preserve_env(:platform_role_management_secret)
    on_exit(restore_secret)

    secret = String.duplicate("platform-management-secret-", 2)
    account = Fixtures.account_fixture()
    stepped_up_subject = Fixtures.step_up(account)

    Application.delete_env(:comms_core, :platform_role_management_secret)

    assert {:error, :platform_role_management_unavailable} =
             Accounts.set_platform_role_from_console(
               account.user.id,
               :platform_operator,
               %{
                 grant_token: secret,
                 actor: "release-engineer@example.test",
                 reason: "staging operations access proof"
               }
             )

    Application.put_env(:comms_core, :platform_role_management_secret, secret)

    assert {:error, :platform_role_console_only} =
             Accounts.create_user(
               %{
                 display_name: "HTTP Platform Operator",
                 email: "http-platform@example.test",
                 password: "correct-horse-http-platform",
                 platform_role: "platform_operator"
               },
               stepped_up_subject
             )

    assert {:error, :platform_role_console_only} =
             Accounts.change_user(
               account.user.id,
               %{version: account.user.lock_version, platform_role: "platform_operator"},
               stepped_up_subject
             )

    attrs = %{
      grant_token: secret,
      actor: "release-engineer@example.test",
      reason: "staging operations access proof"
    }

    assert {:error, :invalid_platform_role_management_secret} =
             Accounts.set_platform_role_from_console(
               account.user.id,
               :platform_operator,
               %{attrs | grant_token: "wrong-secret"}
             )

    assert {:error, :platform_role_audit_context_required} =
             Accounts.set_platform_role_from_console(
               account.user.id,
               :platform_operator,
               Map.delete(attrs, :reason)
             )

    assert {:ok, granted} =
             Accounts.set_platform_role_from_console(
               account.user.id,
               :platform_operator,
               attrs
             )

    assert granted.platform_role == :platform_operator
    platform_subject = Accounts.subject_for_session(account.session)
    assert platform_subject.platform_role == :platform_operator
    assert :ok = Authorization.authorize(:view_platform_operations, platform_subject, %{})
    assert :ok = Authorization.authorize(:operate_platform, platform_subject, %{})

    assert {:ok, issued_ticket} = Accounts.issue_socket_ticket(platform_subject)
    assert {:ok, ticket_subject} = Accounts.consume_socket_ticket(issued_ticket.ticket)
    assert ticket_subject.platform_role == :platform_operator

    assert {:ok, revoked} =
             Accounts.set_platform_role_from_console(account.user.id, "none", %{
               attrs
               | reason: "staging operations access removed"
             })

    assert revoked.platform_role == nil

    assert {:error, :forbidden} =
             Authorization.authorize(:operate_platform, platform_subject, %{})

    assert {:ok, support_user} =
             Accounts.set_platform_role_from_console(account.user.id, :support_operator, %{
               attrs
               | reason: "grant content-blind support visibility"
             })

    assert support_user.platform_role == :support_operator
    support_subject = Accounts.subject_for_session(account.session)
    assert :ok = Authorization.authorize(:view_platform_operations, support_subject, %{})
    assert {:error, :forbidden} = Authorization.authorize(:operate_platform, support_subject, %{})

    assert {:ok, security_user} =
             Accounts.set_platform_role_from_console(account.user.id, :security_operator, %{
               attrs
               | reason: "grant content-blind security visibility"
             })

    assert security_user.platform_role == :security_operator
    security_subject = Accounts.subject_for_session(account.session)
    assert :ok = Authorization.authorize(:view_platform_operations, security_subject, %{})

    assert {:error, :forbidden} =
             Authorization.authorize(:operate_platform, security_subject, %{})

    assert {:ok, _revoked_security} =
             Accounts.set_platform_role_from_console(account.user.id, nil, %{
               attrs
               | reason: "remove content-blind platform visibility"
             })

    assert 5 ==
             Repo.aggregate(
               from(event in AuditEvent,
                 where:
                   event.tenant_id == ^account.tenant.id and
                     event.action in ["platform_role.grant", "platform_role.revoke"]
               ),
               :count
             )
  end

  test "rejects invalid credentials" do
    account = Fixtures.account_fixture()

    assert {:error, :invalid_credentials} =
             Accounts.authenticate(account.tenant.slug, account.user.email, "not-the-password")
  end

  test "a refresh token succeeds only once under concurrent rotation" do
    account = Fixtures.account_fixture()

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Accounts.refresh_session(account.refresh_token) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_refresh_token}, &1)) == 7
    assert {:error, :invalid_refresh_token} = Accounts.refresh_session(account.refresh_token)
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
             Accounts.authenticate(
               account.tenant.slug,
               admin.email,
               admin_password,
               %{name: "Admin browser", platform: "test"}
             )

    admin_subject = Accounts.subject_for_session(admin_login.session)

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

    assert 2 ==
             AuditEvent
             |> where(
               [event],
               event.tenant_id == ^account.tenant.id and event.action == "user.create"
             )
             |> Repo.aggregate(:count)
  end

  defp account_fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end

  defp release_bootstrap_attrs do
    %{
      tenant_name: "Staging Workspace",
      tenant_slug: "staging-workspace",
      display_name: "Staging Owner",
      email: "staging-owner@example.test",
      password: "correct-horse-staging-owner"
    }
  end

  defp preserve_env(key) do
    previous = Application.get_env(:comms_core, key, :not_configured)

    fn ->
      case previous do
        :not_configured -> Application.delete_env(:comms_core, key)
        value -> Application.put_env(:comms_core, key, value)
      end
    end
  end
end
