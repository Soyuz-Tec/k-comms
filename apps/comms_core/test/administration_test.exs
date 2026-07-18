defmodule CommsCore.AdministrationTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Administration, Audit, Governance, Repo}
  alias CommsCore.Administration.{Invitation, InvitationView, InvitedIdentityReceipt}
  alias CommsCore.Accounts.{Session, SocketTicket}
  alias CommsCore.Audit.{Event, TestSupport}
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

  test "invitations are tenant-scoped, idempotent, revocable, and accepted once" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    attrs = %{
      email: "invited@example.test",
      role: "moderator",
      idempotency_key: "invite-001"
    }

    assert {:ok, first} = Administration.create_invitation(attrs, subject)
    assert first.replayed == false
    assert is_binary(first.token)
    assert %InvitationView{} = first.invitation
    assert first.invitation.role == :moderator

    assert {:ok, replay} = Administration.create_invitation(attrs, subject)
    assert replay.replayed == true
    assert replay.invitation.id == first.invitation.id
    assert replay.token == nil
    assert Repo.aggregate(Invitation, :count) == 1

    assert {:ok, invited_user} =
             Administration.accept_invitation(%{
               token: first.token,
               display_name: "Invited Moderator",
               password: "correct-horse-invited-password"
             })

    assert invited_user.tenant_id == account.tenant.id
    assert %InvitedIdentityReceipt{} = invited_user
    assert invited_user.role == :moderator

    assert Password.verify(
             "correct-horse-invited-password",
             Repo.get!(CommsCore.Accounts.User, invited_user.id).password_hash
           )

    assert {:error, :invalid_invitation} =
             Administration.accept_invitation(%{
               token: first.token,
               password: "correct-horse-another-password",
               display_name: "Again"
             })
  end

  test "expired invitations are materialized and do not block re-invitation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, first} =
             Administration.create_invitation(
               %{
                 email: "expiring-invite@example.test",
                 role: "member",
                 idempotency_key: "expiring-invite-1"
               },
               subject
             )

    expired_at = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:microsecond)

    Invitation
    |> Repo.get!(first.invitation.id)
    |> Invitation.changeset(%{expires_at: expired_at})
    |> Repo.update!()

    assert {:ok, replacement} =
             Administration.create_invitation(
               %{
                 email: "expiring-invite@example.test",
                 role: "member",
                 idempotency_key: "expiring-invite-2"
               },
               subject
             )

    assert replacement.invitation.id != first.invitation.id
    assert Repo.get!(Invitation, first.invitation.id).status == :expired
  end

  test "denied invitation creation persists its authorization audit" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:error, :step_up_required} =
             Administration.create_invitation(
               %{
                 email: "denied-invitation@example.test",
                 role: "member",
                 idempotency_key: "denied-invitation"
               },
               subject
             )

    refute Repo.get_by(Invitation,
             tenant_id: account.tenant.id,
             email: "denied-invitation@example.test"
           )

    assert Enum.any?(
             Audit.list(%{
               tenant_id: account.tenant.id,
               actor_user_id: account.user.id,
               action: "authorization.denied",
               limit: 10
             }),
             fn event ->
               event.metadata["permission"] == "manage_invitations" and
                 event.metadata["reason"] == "step_up_required"
             end
           )
  end

  test "invitation acceptance acquires the tenant lock before the invitation row lock" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, invitation_result} =
             Administration.create_invitation(
               %{
                 email: "ordered-lock-invitation@example.test",
                 role: "member",
                 idempotency_key: "ordered-lock-invitation"
               },
               subject
             )

    parent = self()
    handler_id = {__MODULE__, :invitation_acceptance_lock_order, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 send(test_pid, {:invitation_acceptance_query, Map.get(metadata, :query, "")})
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %InvitedIdentityReceipt{}} =
             Administration.accept_invitation(%{
               token: invitation_result.token,
               display_name: "Ordered Lock Invitee",
               password: "correct-horse-ordered-lock-invitee"
             })

    queries = collect_invitation_acceptance_queries([])

    tenant_lock_index =
      Enum.find_index(queries, &String.contains?(&1, "pg_advisory_xact_lock"))

    invitation_row_lock_index =
      Enum.find_index(queries, fn query ->
        String.contains?(query, ~s(FROM "invitations")) and
          String.contains?(query, "FOR UPDATE")
      end)

    assert is_integer(tenant_lock_index)
    assert is_integer(invitation_row_lock_index)
    assert tenant_lock_index < invitation_row_lock_index
  end

  test "an invalid invitation secret does not acquire the tenant admission lock" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, invitation_result} =
             Administration.create_invitation(
               %{
                 email: "invalid-secret-invitation@example.test",
                 role: "member",
                 idempotency_key: "invalid-secret-invitation"
               },
               subject
             )

    invalid_token =
      invitation_result.invitation.id <>
        "." <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    parent = self()
    handler_id = {__MODULE__, :invalid_invitation_secret_lock, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 send(test_pid, {:invalid_invitation_query, Map.get(metadata, :query, "")})
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :invalid_invitation} =
             Administration.accept_invitation(%{
               token: invalid_token,
               display_name: "Rejected Invitee",
               password: "correct-horse-rejected-invitee"
             })

    queries = collect_invalid_invitation_queries([])
    refute Enum.any?(queries, &String.contains?(&1, "pg_advisory_xact_lock"))
    assert Repo.get!(Invitation, invitation_result.invitation.id).status == :pending
  end

  test "invitations reject every existing human identity without changing its lifecycle" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    email = "existing-invitation-identity@example.test"
    original_password = "correct-horse-existing-identity"

    assert {:ok, existing} =
             Accounts.create_user(
               %{
                 display_name: "Existing identity",
                 email: email,
                 password: original_password,
                 role: "member"
               },
               subject
             )

    assert {:error, :invitation_identity_conflict} =
             Administration.create_invitation(
               %{email: email, role: "member", idempotency_key: "existing-active-identity"},
               subject
             )

    assert {:ok, suspended} =
             Accounts.change_user(
               existing.id,
               %{version: existing.lock_version, status: "suspended", reason: "test lifecycle"},
               subject
             )

    assert {:error, :invitation_identity_conflict} =
             Administration.create_invitation(
               %{email: email, role: "member", idempotency_key: "existing-suspended-identity"},
               subject
             )

    assert {:ok, reactivated} =
             Accounts.change_user(
               suspended.id,
               %{
                 version: suspended.lock_version,
                 status: "active",
                 reason: "audited reactivation"
               },
               subject
             )

    assert reactivated.status == :active
    assert Password.verify(original_password, reactivated.password_hash)
  end

  defp collect_invitation_acceptance_queries(queries) do
    receive do
      {:invitation_acceptance_query, query} ->
        collect_invitation_acceptance_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp collect_invalid_invitation_queries(queries) do
    receive do
      {:invalid_invitation_query, query} ->
        collect_invalid_invitation_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  test "invitation acceptance cannot replace or reactivate an identity created after invitation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    email = "invitation-race-identity@example.test"
    original_password = "correct-horse-original-identity"
    invitation_password = "correct-horse-invitation-takeover"

    assert {:ok, invitation_result} =
             Administration.create_invitation(
               %{email: email, role: "admin", idempotency_key: "identity-race-invitation"},
               subject
             )

    assert {:ok, existing} =
             Accounts.create_user(
               %{
                 display_name: "Identity created separately",
                 email: email,
                 password: original_password,
                 role: "member"
               },
               subject
             )

    assert {:ok, suspended} =
             Accounts.change_user(
               existing.id,
               %{version: existing.lock_version, status: "suspended", reason: "test lifecycle"},
               subject
             )

    assert {:error, :invitation_identity_conflict} =
             Administration.accept_invitation(%{
               token: invitation_result.token,
               display_name: "Takeover attempt",
               password: invitation_password
             })

    unchanged = Repo.get!(CommsCore.Accounts.User, suspended.id)
    assert unchanged.status == :suspended
    assert unchanged.role == :member
    assert unchanged.display_name == "Identity created separately"
    assert Password.verify(original_password, unchanged.password_hash)
    refute Password.verify(invitation_password, unchanged.password_hash)
    assert Repo.get!(Invitation, invitation_result.invitation.id).status == :pending
  end

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

  test "profile, password, device, and session self-service are audited" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, second_login} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               fixture_password(account),
               %{name: "Second device", platform: "test"}
             )

    assert {:ok, updated} =
             Accounts.update_profile(%{display_name: "Updated Owner"}, subject)

    assert updated.display_name == "Updated Owner"

    assert {:ok, same_email} =
             Accounts.update_profile(
               %{
                 display_name: "Same Email Owner",
                 email: "  #{String.upcase(account.user.email)}  "
               },
               subject
             )

    assert same_email.display_name == "Same Email Owner"
    assert same_email.email == account.user.email

    assert {:error, :email_change_requires_verification} =
             Accounts.update_profile(
               %{display_name: "Rejected Email Owner", email: "attacker@example.test"},
               subject
             )

    unchanged = Repo.get!(CommsCore.Accounts.User, account.user.id)
    assert unchanged.display_name == "Same Email Owner"
    assert unchanged.email == account.user.email

    assert {:ok, _} =
             Accounts.change_password(
               %{
                 current_password: fixture_password(account),
                 new_password: "correct-horse-new-owner-password"
               },
               subject
             )

    assert {:error, :session_expired} = Accounts.get_active_session(second_login.session_id)
    assert {:ok, device_result} = Accounts.revoke_device(account.device.id, subject)
    assert account.session.id in device_result.revoked_session_ids

    assert Audit.get_by(%{
             tenant_id: account.tenant.id,
             action: "user.password_change"
           })
  end

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

  test "socket tickets are short-lived, hashed, and consumed exactly once" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    stale_id = Ecto.UUID.generate()

    stale_at =
      DateTime.add(DateTime.utc_now(), -7_200, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, _stale} =
             %SocketTicket{id: stale_id}
             |> SocketTicket.changeset(%{
               tenant_id: account.tenant.id,
               user_id: account.user.id,
               device_id: account.device.id,
               session_id: account.session.id,
               token_hash: :crypto.hash(:sha256, "stale-ticket-secret"),
               expires_at: stale_at,
               consumed_at: stale_at
             })
             |> Repo.insert()

    assert {:ok, issued} = Accounts.issue_socket_ticket(subject)
    refute Repo.get(SocketTicket, stale_id)
    assert is_binary(issued.ticket)
    assert issued.expires_in <= 120

    [ticket_id, _secret] = String.split(issued.ticket, ".", parts: 2)
    stored = Repo.get!(SocketTicket, ticket_id)
    refute issued.ticket =~ Base.url_encode64(stored.token_hash, padding: false)
    assert is_nil(stored.consumed_at)

    assert {:ok, consumed_subject} = Accounts.consume_socket_ticket(issued.ticket)
    assert consumed_subject.user_id == account.user.id
    assert Repo.get!(SocketTicket, ticket_id).consumed_at

    assert {:error, :invalid_socket_ticket} = Accounts.consume_socket_ticket(issued.ticket)

    assert 1 == Audit.count(%{tenant_id: account.tenant.id, action: "socket_ticket.issue"})

    assert 1 == Audit.count(%{tenant_id: account.tenant.id, action: "socket_ticket.consume"})
  end

  test "tenant settings use optimistic versioning and privileged audit search" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, initial} = Administration.get_tenant_settings(subject)
    assert initial.settings.lock_version == 1

    assert {:ok, updated} =
             Administration.update_tenant_settings(
               %{
                 version: 1,
                 name: "Governed Workspace",
                 allow_public_channels: false,
                 default_retention_days: 365
               },
               subject
             )

    assert updated.tenant.name == "Governed Workspace"
    assert updated.settings.allow_public_channels == false
    assert updated.settings.default_retention_days == 365

    assert {:error, :stale_version} =
             Administration.update_tenant_settings(
               %{version: 1, max_attachment_bytes: 1000},
               subject
             )

    assert {:ok, audit} =
             Administration.list_audit_events(%{action: "tenant.settings_update"}, subject)

    assert [%Event{resource_id: tenant_id}] = audit.events
    assert tenant_id == account.tenant.id
  end

  test "tenant administration owns its named access policies" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert :ok = Administration.authorize_read_capabilities(subject)
    assert :ok = Administration.authorize_administer_tenant(subject)

    assert {:error, :step_up_required} =
             Administration.authorize_manage_invitations(subject)

    assert {:error, :step_up_required} =
             Administration.authorize_manage_settings(subject)

    assert {:error, :step_up_required} =
             Administration.authorize_audit_tenant(subject)

    denied_events =
      Audit.list(%{
        tenant_id: account.tenant.id,
        actor_user_id: account.user.id,
        action: "authorization.denied",
        limit: 10
      })

    assert Enum.any?(denied_events, fn event ->
             event.metadata["permission"] == "manage_tenant_settings" and
               event.metadata["reason"] == "step_up_required"
           end)

    stepped_up_subject = Fixtures.step_up(account, subject)

    assert :ok = Administration.authorize_read_capabilities(stepped_up_subject)
    assert :ok = Administration.authorize_administer_tenant(stepped_up_subject)
    assert :ok = Administration.authorize_manage_invitations(stepped_up_subject)
    assert :ok = Administration.authorize_manage_settings(stepped_up_subject)
    assert :ok = Administration.authorize_audit_tenant(stepped_up_subject)
    assert {:ok, _settings} = Administration.get_tenant_settings(stepped_up_subject)
    assert {:ok, []} = Administration.list_invitations(stepped_up_subject)
  end

  test "audit reads are audited and compound cursors do not skip equal timestamps" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    rows =
      Enum.map(ids, fn id ->
        %{
          id: id,
          tenant_id: account.tenant.id,
          actor_user_id: account.user.id,
          action: "cursor-test",
          resource_type: "tenant",
          resource_id: account.tenant.id,
          metadata: %{},
          request_id: "cursor-test",
          inserted_at: timestamp
        }
      end)

    assert 2 == rows |> Enum.map(&TestSupport.insert!/1) |> length()

    assert {:ok, first_page} =
             Administration.list_audit_events(%{action: "cursor-test", limit: 1}, subject)

    assert [first] = first_page.events
    assert is_binary(first_page.next_cursor)

    assert {:ok, second_page} =
             Administration.list_audit_events(
               %{action: "cursor-test", limit: 1, cursor: first_page.next_cursor},
               subject
             )

    assert [second] = second_page.events
    refute first.id == second.id

    assert 2 == Audit.count(%{tenant_id: account.tenant.id, action: "audit.read"})
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

  defp fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
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
