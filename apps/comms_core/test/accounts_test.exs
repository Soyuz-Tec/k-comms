defmodule CommsCore.AccountsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Administration}

  alias CommsCore.Accounts.{
    AccessGrant,
    AccessContext,
    AuthenticationResult,
    ConversationBootstrapPort,
    DeviceView,
    InitialConversationCommand,
    InitialConversationReceipt,
    SessionView,
    UserView
  }

  alias CommsCore.Accounts.{Device, PlatformAccess, PlatformRoleGrant, Session, User}
  alias CommsCore.Audit
  alias CommsCore.Administration.{Tenant, TenantView}
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

  test "adapter authentication APIs return stable identity contracts" do
    account = Fixtures.account_fixture()

    assert {:ok,
            %AuthenticationResult{
              session_id: session_id,
              tenant: %TenantView{id: tenant_id, status: :active},
              user: %UserView{},
              device: %DeviceView{}
            }} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               account_fixture_password(account),
               %{name: "Contract browser", platform: "test"}
             )

    assert tenant_id == account.tenant.id

    assert {:ok,
            %AccessContext{
              session: %SessionView{id: ^session_id},
              tenant: %TenantView{id: ^tenant_id, status: :active},
              user: %UserView{},
              device: %DeviceView{}
            }} = Accounts.access_context(session_id, "contract-test")
  end

  test "access grants validate the active tenant, human user, device, and session" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok,
            %AccessGrant{
              tenant_id: tenant_id,
              user_id: user_id,
              device_id: device_id,
              session_id: session_id,
              role: :owner,
              step_up_recent?: false
            }} = Accounts.access_grant(subject)

    assert tenant_id == account.tenant.id
    assert user_id == account.user.id
    assert device_id == account.device.id
    assert session_id == account.session.id

    account.session |> Session.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.device |> Device.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(Device, account.device.id)
    |> Device.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.user |> User.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(User, account.user.id)
    |> User.changeset(%{status: :active})
    |> Repo.update!()

    account.tenant |> Tenant.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(Tenant, account.tenant.id)
    |> Tenant.changeset(%{status: :active})
    |> Repo.update!()

    expired_at = DateTime.add(timestamp, -1, :second)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{expires_at: expired_at})
    |> Repo.update!()

    assert {:error, :forbidden} = Accounts.access_grant(subject)
  end

  test "inactive privileged subjects retain verified denial audit evidence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    account.session |> Session.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 1

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.device |> Device.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 2

    Repo.get!(Device, account.device.id)
    |> Device.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.user |> User.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 3

    Repo.get!(User, account.user.id)
    |> User.changeset(%{status: :active})
    |> Repo.update!()

    account.tenant |> Tenant.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 4
  end

  test "identity authorization uses persisted role and recent step-up facts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert :ok =
             Accounts.authorize_receive_user_events(subject, %{user_id: account.user.id})

    assert {:error, :forbidden} =
             Accounts.authorize_receive_user_events(subject, %{user_id: Ecto.UUID.generate()})

    assert {:error, :step_up_required} =
             Accounts.authorize_manage_user_lifecycle(subject)

    assert {:error, :step_up_required} = Accounts.authorize_manage_sessions(subject)

    stepped_up_subject = Fixtures.step_up(account, subject)

    assert {:ok, %AccessGrant{role: :owner, step_up_recent?: true}} =
             Accounts.access_grant(stepped_up_subject)

    assert :ok = Accounts.authorize_manage_user_lifecycle(stepped_up_subject)
    assert :ok = Accounts.authorize_manage_sessions(stepped_up_subject)

    stale_step_up =
      DateTime.utc_now()
      |> DateTime.add(
        -Application.get_env(:comms_core, :step_up_ttl_seconds, 300) - 1,
        :second
      )
      |> DateTime.truncate(:microsecond)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{step_up_at: stale_step_up})
    |> Repo.update!()

    assert {:ok, %AccessGrant{step_up_recent?: false}} =
             Accounts.access_grant(stepped_up_subject)

    assert {:error, :step_up_required} =
             Accounts.authorize_manage_user_lifecycle(stepped_up_subject)
  end

  test "governance erasure requires a caller-owned transaction" do
    account = Fixtures.account_fixture()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:error, :invalid_erasure_command} =
             Accounts.erase_user_for_governance(%{
               tenant_id: account.tenant.id,
               user_id: "not-a-uuid",
               pending_deletion_user_ids: [],
               timestamp: timestamp
             })

    assert {:error, :transaction_required} =
             Accounts.erase_user_for_governance(%{
               tenant_id: account.tenant.id,
               user_id: account.user.id,
               pending_deletion_user_ids: [],
               timestamp: timestamp
             })
  end

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

  test "governance erasure anonymizes the user and revokes IdentityAccess state" do
    account = Fixtures.account_fixture()
    _remaining_owner = Fixtures.user_fixture(account, %{role: :owner})
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    original_version = account.user.lock_version

    assert {:ok, {:ok, %{user_id: user_id, revoked_session_ids: revoked_session_ids}}} =
             Repo.transaction(fn ->
               Accounts.erase_user_for_governance(%{
                 tenant_id: account.tenant.id,
                 user_id: account.user.id,
                 pending_deletion_user_ids: [],
                 timestamp: timestamp
               })
             end)

    assert user_id == account.user.id
    assert revoked_session_ids == [account.session.id]

    erased_user = Repo.get!(User, account.user.id)
    assert erased_user.external_subject == "deleted-#{account.user.id}"
    assert erased_user.display_name == "Deleted user"
    assert erased_user.email == "deleted-#{account.user.id}@invalid.example"
    assert erased_user.status == :deleted
    assert erased_user.lock_version == original_version + 1

    assert Repo.get!(Session, account.session.id).revoked_at == timestamp
    assert Repo.get!(Device, account.device.id).revoked_at == timestamp
  end

  test "governance erasure excludes pending deletions from last-owner safety" do
    account = Fixtures.account_fixture()
    pending_owner = Fixtures.user_fixture(account, %{role: :owner}).user
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, {:error, :last_owner_required}} =
             Repo.transaction(fn ->
               Accounts.erase_user_for_governance(%{
                 tenant_id: account.tenant.id,
                 user_id: account.user.id,
                 pending_deletion_user_ids: [pending_owner.id],
                 timestamp: timestamp
               })
             end)

    assert Repo.get!(User, account.user.id).status == :active
    refute Repo.get!(Session, account.session.id).revoked_at
    refute Repo.get!(Device, account.device.id).revoked_at
  end

  test "bootstrap returns foreign owner views instead of persistence structs" do
    suffix = System.unique_integer([:positive, :monotonic])

    assert {:ok, result} =
             Accounts.bootstrap_tenant(%{
               tenant_name: "Boundary #{suffix}",
               tenant_slug: "boundary-#{suffix}",
               display_name: "Boundary Owner",
               email: "boundary-#{suffix}@example.test",
               password: "correct-horse-boundary-#{suffix}",
               device_name: "Boundary browser",
               device_platform: "test"
             })

    assert %TenantView{} = result.tenant
    assert %InitialConversationReceipt{} = result.conversation
  end

  test "owner-contributed bootstrap writes roll back after a later failure" do
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()

    result =
      Ecto.Multi.new()
      |> Administration.append_bootstrap_tenant(:tenant, %{
        id: tenant_id,
        name: "Rollback tenant",
        slug: "rollback-#{System.unique_integer([:positive, :monotonic])}"
      })
      |> Ecto.Multi.insert(
        :user,
        User.changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: "local:rollback@example.test",
          display_name: "Rollback owner",
          email: "rollback-#{user_id}@example.test",
          password_hash: Password.hash("correct-horse-rollback"),
          account_type: :human,
          role: :owner,
          status: :active
        })
      )
      |> ConversationBootstrapPort.append_initial_channel(
        :conversation,
        %InitialConversationCommand{
          id: conversation_id,
          tenant_id: tenant_id,
          owner_user_id: user_id,
          joined_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }
      )
      |> Ecto.Multi.run(:forced_failure, fn _repo, _changes ->
        {:error, :forced_failure}
      end)
      |> Repo.transaction()

    assert {:error, :forced_failure, :forced_failure, _changes} = result
    refute Repo.get(Tenant, tenant_id)
    refute Repo.get(User, user_id)
    refute Repo.get(Conversation, conversation_id)
    refute Repo.get_by(Membership, conversation_id: conversation_id)
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
    assert Audit.count(%{tenant_id: created.tenant.id}) == 1
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
    assert Audit.count(%{tenant_id: created.tenant.id}) == 1
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

    # A subject minted for an earlier grant cannot regain authority when the
    # same role is later granted again with a different deadline.
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

    # Reproduce the exact role/deadline collision that would revive the first
    # subject if the authorization boundary did not also bind the approval id.
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

  test "rejects invalid credentials" do
    account = Fixtures.account_fixture()

    assert {:error, :invalid_credentials} =
             Accounts.authenticate(account.tenant.slug, account.user.email, "not-the-password")
  end

  test "tenant inactivity fails closed across sign-in, refresh, and active-session lookup" do
    account = Fixtures.account_fixture()

    account.tenant
    |> Tenant.changeset(%{status: :suspended})
    |> Repo.update!()

    assert {:error, :invalid_credentials} =
             Accounts.authenticate(
               account.tenant.slug,
               account.user.email,
               account_fixture_password(account)
             )

    assert {:error, :invalid_refresh_token} = Accounts.refresh_session(account.refresh_token)
    assert {:error, :session_expired} = Accounts.get_active_session(account.session.id)
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

  test "the previous release can insert a session without the absolute-expiry column" do
    account = Fixtures.account_fixture()
    session_id = Ecto.UUID.generate()

    inserted_at =
      DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)

    expires_at = NaiveDateTime.add(inserted_at, 600, :second)

    assert {:ok, [[true, true]]} =
             Repo.transaction(fn ->
               Ecto.Adapters.SQL.query!(Repo, "SET LOCAL TIME ZONE 'Asia/Kolkata'")

               Ecto.Adapters.SQL.query!(
                 Repo,
                 """
                 INSERT INTO sessions (
                   id, tenant_id, user_id, device_id, refresh_token_hash,
                   expires_at, last_used_at, inserted_at, updated_at
                 )
                 VALUES (
                   $1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5,
                   $6::timestamp, $7::timestamp, $7::timestamp, $7::timestamp
                 )
                 RETURNING
                   absolute_expires_at =
                     (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '30 days',
                   absolute_expires_at > expires_at
                 """,
                 [
                   session_id,
                   account.tenant.id,
                   account.user.id,
                   account.device.id,
                   :crypto.strong_rand_bytes(32),
                   expires_at,
                   inserted_at
                 ]
               ).rows
             end)

    assert %Session{absolute_expires_at: %DateTime{}} = Repo.get!(Session, session_id)
  end

  test "refresh rotation cannot extend a session beyond its immutable creation lifetime" do
    restore_sliding = preserve_env(:session_ttl_seconds)
    restore_absolute = preserve_env(:session_absolute_ttl_seconds)

    on_exit(fn ->
      restore_sliding.()
      restore_absolute.()
    end)

    Application.put_env(:comms_core, :session_ttl_seconds, 600)
    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 60)

    account = Fixtures.account_fixture()
    absolute_deadline = account.session.absolute_expires_at

    assert DateTime.diff(absolute_deadline, account.session.inserted_at, :second) in 59..60

    changed_deadline = DateTime.add(absolute_deadline, 600, :second)

    refute account.session
           |> Session.changeset(%{absolute_expires_at: changed_deadline})
           |> Map.fetch!(:valid?)

    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 3_600)

    from(session in Session, where: session.id == ^account.session.id)
    |> Repo.update_all(set: [expires_at: DateTime.add(absolute_deadline, 600, :second)])

    assert {:ok, refreshed} = Accounts.refresh_session(account.refresh_token)
    assert refreshed.session.absolute_expires_at == absolute_deadline
    assert refreshed.session.expires_at == absolute_deadline
  end

  test "absolute session expiry rejects refresh and active-session lookup" do
    restore_sliding = preserve_env(:session_ttl_seconds)
    restore_absolute = preserve_env(:session_absolute_ttl_seconds)

    on_exit(fn ->
      restore_sliding.()
      restore_absolute.()
    end)

    Application.put_env(:comms_core, :session_ttl_seconds, 600)
    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 0)

    account = Fixtures.account_fixture()
    assert account.session.expires_at == account.session.absolute_expires_at

    assert {:error, :session_expired} = Accounts.get_active_session(account.session.id)

    assert {:error, :session_expired} =
             Accounts.step_up(
               %{current_password: account_fixture_password(account)},
               Fixtures.subject(account)
             )

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

    assert 2 == Audit.count(%{tenant_id: account.tenant.id, action: "user.create"})
  end

  defp account_fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end

  defp denial_count(account) do
    Audit.count(%{
      tenant_id: account.tenant.id,
      actor_user_id: account.user.id,
      action: "authorization.denied"
    })
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
