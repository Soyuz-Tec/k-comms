defmodule CommsCore.Accounts.RolePermissionsTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures
  alias CommsCore.{Accounts, Administration, Conversations, Governance, Messaging, Repo}
  alias CommsCore.Accounts.{RolePermissions, Session, User}
  alias CommsTestSupport.Fixtures
  @moduletag :integration

  test "six-role capability facts match actual owner facade eligibility" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, catalog} = Accounts.list_fixed_role_permissions(subject)
    assert Enum.map(catalog, & &1.role) == RolePermissions.roles()

    for role <- RolePermissions.roles() do
      set_role(account, role, :workspace)
      facts = Enum.find(catalog, &(&1.role == role)).capabilities

      for {capability, result} <- actual_decisions(subject) do
        eligible? = result == :ok

        assert eligible? == Enum.any?(facts, &(&1.capability == capability)),
               "#{role} / #{capability} disagrees with the owner facade"
      end
    end
  end

  test "capability conditions preserve step-up and conversation-only scope distinctions" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    for role <- RolePermissions.roles() do
      set_role(account, role, :conversation_only)
      assert RolePermissions.capabilities(role, :conversation_only) == []

      assert {:ok, %{account_type: :human, access_scope: :conversation_only}} =
               Accounts.access_grant(subject)

      assert {:error, :forbidden} = Accounts.resolve_access(subject)

      for {capability, result} <- actual_decisions(subject) do
        assert result == {:error, :forbidden},
               "limited #{role} must not receive #{capability}"
      end
    end

    set_role(account, :owner, :workspace)

    Repo.update_all(from(session in Session, where: session.id == ^account.session.id),
      set: [step_up_at: nil]
    )

    assert {:ok, catalog} = Accounts.list_fixed_role_permissions(subject)
    facts = Enum.find(catalog, &(&1.role == :owner)).capabilities

    for {capability, result} <- actual_decisions(subject) do
      fact = Enum.find(facts, &(&1.capability == capability))

      if :recent_step_up in fact.conditions,
        do: assert(result == {:error, :step_up_required}),
        else: assert(result == :ok)
    end
  end

  test "role changes cannot enroll a limited human into tenant privileges" do
    account = Fixtures.account_fixture()
    target = limited_user_fixture(account)
    subject = Fixtures.step_up(account)

    for role <- [:owner, :admin, :compliance_admin, :security_admin] do
      assert {:ok, preview} =
               Accounts.preview_user_role_change(
                 target.id,
                 %{role: role, version: target.lock_version},
                 subject
               )

      assert preview.target_access_scope == :conversation_only
      refute preview.role_policy_allows
      assert preview.blockers == [:forbidden]
      assert preview.added == [] and preview.removed == []

      assert {:error, :forbidden} =
               Governance.change_user_lifecycle_view(
                 target.id,
                 %{
                   role: role,
                   version: target.lock_version,
                   reason: "Attempt limited tenant promotion"
                 },
                 subject
               )

      current = Repo.get!(User, target.id)
      assert current.role == :member and current.access_scope == :conversation_only
      assert current.lock_version == target.lock_version
    end

    assert {:ok, preview} =
             Accounts.preview_user_role_change(
               target.id,
               %{role: :moderator, version: target.lock_version},
               subject
             )

    assert preview.role_policy_allows and preview.added == []

    assert {:ok, %{user: %{role: :moderator}}} =
             Governance.change_user_lifecycle_view(
               target.id,
               %{
                 role: :moderator,
                 version: target.lock_version,
                 reason: "Keep scoped moderation role"
               },
               subject
             )

    current = Repo.get!(User, target.id)
    assert current.access_scope == :conversation_only

    assert {:ok, %{user: %{status: :suspended}}} =
             Governance.change_user_lifecycle_view(
               target.id,
               %{
                 status: :suspended,
                 version: current.lock_version,
                 reason: "Suspend scoped identity"
               },
               subject
             )

    assert Repo.get!(User, target.id).access_scope == :conversation_only

    legacy =
      limited_user_fixture(account, %{role: :security_admin})

    assert {:ok, preview} =
             Accounts.preview_user_role_change(
               legacy.id,
               %{role: :member, version: legacy.lock_version},
               subject
             )

    assert preview.role_policy_allows and preview.added == [] and preview.removed == []

    assert {:ok, %{user: %{role: :member}}} =
             Governance.change_user_lifecycle_view(
               legacy.id,
               %{
                 role: :member,
                 version: legacy.lock_version,
                 reason: "Remove an existing scoped elevated role"
               },
               subject
             )

    assert Repo.get!(User, legacy.id).access_scope == :conversation_only
  end

  test "tenant scope guards preserve actual Guest and converted limited room messages" do
    enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    on_exit(fn ->
      restore_env(:instant_rooms_enabled, enabled)
      restore_env(:instant_room_tenant_slug, slug)
    end)

    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    guest = guest_subject(created)
    assert {:ok, %{account_type: :guest}} = Accounts.access_grant(guest)
    assert {:error, :forbidden} = Accounts.resolve_access(guest)
    assert {:error, :forbidden} = Governance.list_legal_hold_views(%{}, guest)
    assert {:ok, _, :created} = room_message(created.conversation.id, guest, "guest")

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: "role-conversion-#{guest.user_id}@example.test",
                 password: "scoped-role-conversion-password-1234",
                 display_name: "Scoped member",
                 device: %{name: "Scoped browser", platform: "test"}
               },
               guest
             )

    human = authenticated_subject(converted.authentication)

    assert {:ok, %{account_type: :human, access_scope: :conversation_only}} =
             Accounts.access_grant(human)

    assert {:error, :forbidden} = Accounts.resolve_access(human)
    assert {:error, :forbidden} = Governance.list_legal_hold_views(%{}, human)
    assert {:ok, _, :created} = room_message(created.conversation.id, human, "converted")
  end

  test "owner preview and actual governed change share the privileged assignment policy" do
    account = Fixtures.account_fixture()
    target = Fixtures.user_fixture(account).user
    subject = Fixtures.step_up(account)

    assert {:ok, preview} =
             Accounts.preview_user_role_change(
               target.id,
               %{role: "compliance_admin", version: target.lock_version},
               subject
             )

    assert preview.advisory and preview.governance_review_required
    assert preview.role_policy_allows and preview.blockers == []
    assert Enum.map(preview.added, & &1.capability) == [:audit_tenant, :govern_tenant]
    assert Repo.get!(User, target.id).role == :member

    assert {:ok, %{user: %{role: :compliance_admin}}} =
             Governance.change_user_lifecycle_view(
               target.id,
               %{
                 role: "compliance_admin",
                 version: preview.current_version,
                 reason: "Grant existing fixed compliance duties"
               },
               subject
             )

    assert {:error, :stale_version} =
             Accounts.preview_user_role_change(
               target.id,
               %{role: "member", version: preview.current_version},
               subject
             )
  end

  test "admin preview refuses elevated roles and permits the same moderator change as Governance" do
    account = Fixtures.account_fixture()
    target = Fixtures.user_fixture(account).user
    set_role(account, :admin, :workspace)
    subject = Fixtures.step_up(account)

    for role <- [:owner, :admin, :compliance_admin, :security_admin] do
      assert {:ok, preview} =
               Accounts.preview_user_role_change(
                 target.id,
                 %{role: role, version: target.lock_version},
                 subject
               )

      refute preview.role_policy_allows
      assert :forbidden in preview.blockers

      assert {:error, :forbidden} =
               Governance.change_user_lifecycle_view(
                 target.id,
                 %{
                   role: role,
                   version: target.lock_version,
                   reason: "Attempt a protected fixed role"
                 },
                 subject
               )

      assert Repo.get!(User, target.id).role == :member
    end

    assert {:ok, preview} =
             Accounts.preview_user_role_change(
               target.id,
               %{role: :moderator, version: target.lock_version},
               subject
             )

    assert preview.role_policy_allows and preview.blockers == []

    assert {:ok, %{user: %{role: :moderator}}} =
             Governance.change_user_lifecycle_view(
               target.id,
               %{
                 role: :moderator,
                 version: preview.current_version,
                 reason: "Assign moderation role"
               },
               subject
             )

    elevated = Fixtures.user_fixture(account, %{role: :security_admin}).user

    assert {:ok, preview} =
             Accounts.preview_user_role_change(
               elevated.id,
               %{role: :member, version: elevated.lock_version},
               subject
             )

    refute preview.role_policy_allows

    assert {:error, :forbidden} =
             Governance.change_user_lifecycle_view(
               elevated.id,
               %{
                 role: :member,
                 version: elevated.lock_version,
                 reason: "Attempt privileged demotion"
               },
               subject
             )
  end

  test "last-owner demotion is advisory-blocked and revoked actors receive no preview" do
    account = Fixtures.account_fixture()

    limited_owner =
      limited_user_fixture(account, %{role: :owner})

    subject = Fixtures.step_up(account)

    assert {:ok, preview} =
             Accounts.preview_user_role_change(
               account.user.id,
               %{role: :admin, version: account.user.lock_version},
               subject
             )

    assert preview.role_policy_allows
    assert preview.blockers == [:last_owner_required]

    assert {:error, :last_owner_required} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{
                 role: :admin,
                 version: account.user.lock_version,
                 reason: "Attempt sole-owner demotion"
               },
               subject
             )

    assert :ok = Accounts.revoke_own_session_command(account.session.id, subject)

    assert {:error, :forbidden} =
             Accounts.preview_user_role_change(
               account.user.id,
               %{role: :admin, version: account.user.lock_version},
               subject
             )

    assert {:error, :forbidden} = Accounts.list_fixed_role_permissions(subject)
    assert Repo.get!(User, account.user.id).role == :owner
    assert Repo.get!(User, account.user.id).lock_version == account.user.lock_version
    assert Repo.get!(User, limited_owner.id).role == :owner
    assert Repo.get!(User, limited_owner.id).access_scope == :conversation_only
  end

  defp limited_user_fixture(account, overrides \\ %{}) do
    # Normal identity changes deliberately cannot widen or narrow access scope.
    # Retain this synthetic predecessor state explicitly for legacy regressions.
    account
    |> Fixtures.user_fixture(overrides)
    |> Map.fetch!(:user)
    |> Ecto.Changeset.change(access_scope: :conversation_only)
    |> Repo.update!()
  end

  defp actual_decisions(subject) do
    governance =
      case Governance.list_legal_hold_views(%{}, subject) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end

    [
      administer_users: Accounts.authorize_administer_users(subject),
      manage_user_lifecycle: Accounts.authorize_manage_user_lifecycle(subject),
      manage_sessions: Accounts.authorize_manage_sessions(subject),
      manage_tenant_settings: Administration.authorize_manage_settings(subject),
      manage_invitations: Administration.authorize_manage_invitations(subject),
      audit_tenant: Administration.authorize_audit_tenant(subject),
      govern_tenant: governance
    ]
  end

  defp set_role(account, role, scope) do
    Repo.update_all(from(user in User, where: user.id == ^account.user.id),
      set: [role: role, access_scope: scope]
    )
  end

  defp room_message(conversation_id, subject, key) do
    Messaging.accept_message_with_status(
      %{
        tenant_id: subject.tenant_id,
        conversation_id: conversation_id,
        sender_user_id: subject.user_id,
        sender_device_id: subject.device_id,
        client_message_id: "role-scope-" <> key,
        body: "Scoped role policy #{key}"
      },
      subject
    )
  end
end
