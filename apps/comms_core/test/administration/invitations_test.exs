defmodule CommsCore.Administration.InvitationsTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :governance

  alias CommsCore.{Accounts, Administration, Audit, Repo}
  alias CommsCore.Administration.{Invitation, InvitationView, InvitedIdentityReceipt}
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
end
