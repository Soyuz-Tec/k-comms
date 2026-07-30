defmodule CommsCore.Accounts.PlatformGrantsTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Audit, Repo}
  alias CommsCore.Accounts.{AccessGrant, PlatformAccess, PlatformRoleGrant, User}
  alias CommsTestSupport.Fixtures

  @moduletag :integration

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

    assert Audit.count(%{
             tenant_id: created.tenant.id,
             action: "platform_role.bootstrap_grant"
           }) == 1

    assert {:ok, existing} = Accounts.bootstrap_tenant_once(attrs)
    assert existing.user.platform_role == :platform_operator

    assert Audit.count(%{
             tenant_id: created.tenant.id,
             action: "platform_role.bootstrap_grant"
           }) == 1
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
                 reason: "staging operations access proof",
                 ttl_seconds: 3600
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
      reason: "staging operations access proof",
      ttl_seconds: 3600
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

    for invalid_ttl <- [nil, 299, 28_801, "not-a-number"] do
      assert {:error, :invalid_platform_role_ttl} =
               Accounts.set_platform_role_from_console(
                 account.user.id,
                 :platform_operator,
                 Map.put(attrs, :ttl_seconds, invalid_ttl)
               )
    end

    assert {:ok, granted} =
             Accounts.set_platform_role_from_console(
               account.user.id,
               :platform_operator,
               attrs
             )

    assert granted.platform_role == :platform_operator
    assert %DateTime{} = granted.platform_role_expires_at

    assert DateTime.diff(granted.platform_role_expires_at, DateTime.utc_now(), :second) in 3598..3600

    [grant_audit] =
      Audit.list(%{
        tenant_id: account.tenant.id,
        action: "platform_role.grant",
        limit: 1
      })

    assert grant_audit.metadata["ttl_seconds"] == 3600
    assert is_binary(grant_audit.metadata["after_expires_at"])
    platform_subject = Accounts.subject_for_session(account.session)
    assert platform_subject.platform_role == :platform_operator
    assert is_binary(platform_subject.platform_role_grant_id)
    assert platform_subject.platform_role_expires_at == granted.platform_role_expires_at

    assert {:ok,
            %AccessGrant{
              platform_role: :platform_operator,
              platform_claim_verified?: true
            }} = Accounts.access_grant(platform_subject)

    assert :ok = Accounts.authorize_view_platform_operations(platform_subject)
    assert :ok = Accounts.authorize_operate_platform(platform_subject)

    assert {:ok, issued_ticket} = Accounts.issue_socket_ticket(platform_subject)
    assert {:ok, ticket_subject} = Accounts.consume_socket_ticket(issued_ticket.ticket)
    assert ticket_subject.platform_role == :platform_operator
    assert ticket_subject.platform_role_grant_id == platform_subject.platform_role_grant_id
    assert ticket_subject.platform_role_expires_at == granted.platform_role_expires_at

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    old_inserted_at = DateTime.add(expired_at, -3600, :second)

    Repo.update_all(
      from(grant in PlatformRoleGrant, where: grant.user_id == ^account.user.id),
      set: [expires_at: expired_at, inserted_at: old_inserted_at]
    )

    assert %{platform_role: nil, platform_role_expires_at: nil} =
             PlatformAccess.for_user(account.user)

    assert {:ok,
            %AccessGrant{
              platform_role: nil,
              platform_claim_verified?: false
            }} = Accounts.access_grant(platform_subject)

    assert {:error, :forbidden} =
             Accounts.authorize_operate_platform(platform_subject)

    assert {:ok, renewed} =
             Accounts.set_platform_role_from_console(
               account.user.id,
               :platform_operator,
               %{attrs | reason: "renew expired platform operations access"}
             )

    renewed_subject = Accounts.subject_for_session(account.session)
    assert renewed.platform_role_expires_at == renewed_subject.platform_role_expires_at
    assert :ok = Accounts.authorize_operate_platform(renewed_subject)

    assert {:error, :forbidden} =
             Accounts.authorize_operate_platform(platform_subject)

    assert {:ok, revoked} =
             Accounts.set_platform_role_from_console(account.user.id, "none", %{
               attrs
               | reason: "staging operations access removed"
             })

    assert revoked.platform_role == nil

    assert {:error, :forbidden} =
             Accounts.authorize_operate_platform(platform_subject)

    assert {:ok, support_user} =
             Accounts.set_platform_role_from_console(account.user.id, :support_operator, %{
               attrs
               | reason: "grant content-blind support visibility"
             })

    assert support_user.platform_role == :support_operator
    support_subject = Accounts.subject_for_session(account.session)
    assert :ok = Accounts.authorize_view_platform_operations(support_subject)
    assert {:error, :forbidden} = Accounts.authorize_operate_platform(support_subject)

    assert {:ok, security_user} =
             Accounts.set_platform_role_from_console(account.user.id, :security_operator, %{
               attrs
               | reason: "grant content-blind security visibility"
             })

    assert security_user.platform_role == :security_operator
    security_subject = Accounts.subject_for_session(account.session)
    assert :ok = Accounts.authorize_view_platform_operations(security_subject)

    assert {:error, :forbidden} =
             Accounts.authorize_operate_platform(security_subject)

    assert {:ok, _revoked_security} =
             Accounts.set_platform_role_from_console(account.user.id, nil, %{
               attrs
               | reason: "remove content-blind platform visibility"
             })

    assert 6 ==
             Audit.count(%{tenant_id: account.tenant.id, action: "platform_role.grant"}) +
               Audit.count(%{tenant_id: account.tenant.id, action: "platform_role.revoke"})
  end

  test "every platform-role approval rotates its grant id and exact tuple collisions stay denied" do
    restore_secret = preserve_env(:platform_role_management_secret)
    on_exit(restore_secret)

    secret = String.duplicate("platform-management-secret-", 2)
    Application.put_env(:comms_core, :platform_role_management_secret, secret)
    account = Fixtures.account_fixture()

    attrs = %{
      grant_token: secret,
      actor: "release-engineer@example.test",
      reason: "exercise platform grant generation binding",
      ttl_seconds: 3600
    }

    assert {:ok, _first} =
             Accounts.set_platform_role_from_console(account.user.id, :platform_operator, attrs)

    first_subject = Accounts.subject_for_session(account.session)
    first_grant = Repo.get_by!(PlatformRoleGrant, user_id: account.user.id)
    assert first_subject.platform_role_grant_id == first_grant.id

    assert {:ok, _renewed} =
             Accounts.set_platform_role_from_console(account.user.id, :platform_operator, %{
               attrs
               | reason: "renew the same platform role with a new approval"
             })

    renewed_grant = Repo.get_by!(PlatformRoleGrant, user_id: account.user.id)
    refute renewed_grant.id == first_grant.id

    Repo.update_all(
      from(grant in PlatformRoleGrant, where: grant.id == ^renewed_grant.id),
      set: [expires_at: first_subject.platform_role_expires_at]
    )

    current_subject = Accounts.subject_for_session(account.session)
    assert current_subject.platform_role == first_subject.platform_role
    assert current_subject.platform_role_expires_at == first_subject.platform_role_expires_at
    assert current_subject.platform_role_grant_id == renewed_grant.id
    assert :ok = Accounts.authorize_operate_platform(current_subject)

    assert {:error, :forbidden} =
             Accounts.authorize_operate_platform(first_subject)
  end

  test "platform grants accept exact TTL limits, expire at equality, and require active humans" do
    restore_secret = preserve_env(:platform_role_management_secret)
    on_exit(restore_secret)

    secret = String.duplicate("platform-management-secret-", 2)
    Application.put_env(:comms_core, :platform_role_management_secret, secret)
    account = Fixtures.account_fixture()

    attrs = %{
      grant_token: secret,
      actor: "release-engineer@example.test",
      reason: "verify exact platform grant security boundaries",
      ttl_seconds: 300
    }

    assert {:ok, minimum} =
             Accounts.set_platform_role_from_console(account.user.id, :platform_operator, attrs)

    assert DateTime.diff(minimum.platform_role_expires_at, DateTime.utc_now(), :second) in 298..300

    minimum_subject = Accounts.subject_for_session(account.session)
    boundary = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    grant = Repo.get_by!(PlatformRoleGrant, user_id: account.user.id)

    refute PlatformRoleGrant.active_at?(%{grant | expires_at: boundary}, boundary)

    Repo.update_all(
      from(candidate in PlatformRoleGrant, where: candidate.id == ^grant.id),
      set: [expires_at: boundary, inserted_at: DateTime.add(boundary, -300, :second)]
    )

    assert {:error, :forbidden} =
             Accounts.authorize_operate_platform(minimum_subject)

    assert {:ok, maximum} =
             Accounts.set_platform_role_from_console(account.user.id, :platform_operator, %{
               attrs
               | reason: "verify the maximum platform grant duration",
                 ttl_seconds: 28_800
             })

    assert DateTime.diff(maximum.platform_role_expires_at, DateTime.utc_now(), :second) in 28_798..28_800

    Repo.update_all(
      from(user in User, where: user.id == ^account.user.id),
      set: [status: :suspended]
    )

    assert {:error, :not_found} =
             Accounts.set_platform_role_from_console(account.user.id, :platform_operator, attrs)

    assert {:ok, revoked} =
             Accounts.set_platform_role_from_console(account.user.id, nil, %{
               attrs
               | reason: "revoke platform access from a suspended identity"
             })

    assert revoked.platform_role == nil
    refute Repo.get_by(PlatformRoleGrant, user_id: account.user.id)

    non_human = Fixtures.account_fixture()

    Repo.update_all(
      from(user in User, where: user.id == ^non_human.user.id),
      set: [account_type: :service]
    )

    assert {:error, :not_found} =
             Accounts.set_platform_role_from_console(non_human.user.id, :platform_operator, attrs)

    assert {:ok, revoked_non_human} =
             Accounts.set_platform_role_from_console(non_human.user.id, nil, %{
               attrs
               | reason: "allow cleanup of any non-human platform grant state"
             })

    assert revoked_non_human.platform_role == nil
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
