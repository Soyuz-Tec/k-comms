defmodule CommsCore.Conversations.MembershipsTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  @tag :concurrency
  test "concurrent owner changes preserve an active conversation owner" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 kind: "channel",
                 title: "Ownership race",
                 visibility: "tenant",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, memberships} = Conversations.list_members(conversation.id, subject)
    owner_membership = Enum.find(memberships, &(&1.user.id == account.user.id)).membership
    member_membership = Enum.find(memberships, &(&1.user.id == member.user.id)).membership

    assert {:ok, second_owner} =
             Conversations.change_member_role(
               conversation.id,
               member.user.id,
               %{version: member_membership.lock_version, role: "owner"},
               subject
             )

    operations = [
      fn ->
        Conversations.change_member_role(
          conversation.id,
          account.user.id,
          %{version: owner_membership.lock_version, role: "member"},
          subject
        )
      end,
      fn ->
        Conversations.remove_member(
          conversation.id,
          member.user.id,
          %{version: second_owner.lock_version},
          subject
        )
      end
    ]

    results =
      operations
      |> Task.async_stream(fn operation -> operation.() end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert {:ok, remaining} = Conversations.list_members(conversation.id, subject)
    assert Enum.count(remaining, &(&1.membership.role == :owner)) == 1
  end

  test "moderators manage ordinary memberships but cannot act on conversation owners" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {moderator, moderator_subject} = role_subject_fixture(account, :moderator)
    ordinary_member = Fixtures.user_fixture(account).user
    unjoined_member = Fixtures.user_fixture(account).user

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 kind: "group",
                 title: "Ownership boundary",
                 visibility: "private",
                 member_ids: [moderator.id, ordinary_member.id]
               },
               owner_subject
             )

    assert {:ok, initial_memberships} =
             Conversations.list_members(conversation.id, owner_subject)

    moderator_membership =
      Enum.find(initial_memberships, &(&1.user.id == moderator.id)).membership

    ordinary_membership =
      Enum.find(initial_memberships, &(&1.user.id == ordinary_member.id)).membership

    owner_membership =
      Enum.find(initial_memberships, &(&1.user.id == account.user.id)).membership

    assert {:ok, promoted_moderator} =
             Conversations.change_member_role(
               conversation.id,
               moderator.id,
               %{version: moderator_membership.lock_version, role: "moderator"},
               owner_subject
             )

    assert {:ok, promoted_ordinary_member} =
             Conversations.change_member_role(
               conversation.id,
               ordinary_member.id,
               %{version: ordinary_membership.lock_version, role: "moderator"},
               moderator_subject
             )

    event_count =
      Repo.aggregate(
        from(event in OutboxEvent,
          where:
            event.tenant_id == ^account.tenant.id and
              event.aggregate_id == ^conversation.id and
              event.event_type == "membership.changed.v1"
        ),
        :count
      )

    assert {:ok, idempotent_membership} =
             Conversations.add_member(
               conversation.id,
               ordinary_member.id,
               :moderator,
               moderator_subject
             )

    assert idempotent_membership.id == promoted_ordinary_member.id
    assert idempotent_membership.lock_version == promoted_ordinary_member.lock_version

    assert event_count ==
             Repo.aggregate(
               from(event in OutboxEvent,
                 where:
                   event.tenant_id == ^account.tenant.id and
                     event.aggregate_id == ^conversation.id and
                     event.event_type == "membership.changed.v1"
               ),
               :count
             )

    assert {:error, :version_required} =
             Conversations.add_member(
               conversation.id,
               ordinary_member.id,
               :member,
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.add_member(
               conversation.id,
               unjoined_member.id,
               :owner,
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.change_member_role(
               conversation.id,
               moderator.id,
               %{version: promoted_moderator.lock_version, role: "owner"},
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.change_member_role(
               conversation.id,
               ordinary_member.id,
               %{version: promoted_ordinary_member.lock_version, role: "owner"},
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.change_member_role(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version, role: "moderator"},
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.remove_member(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version},
               moderator_subject
             )

    assert {:ok, second_owner} =
             Conversations.change_member_role(
               conversation.id,
               ordinary_member.id,
               %{version: promoted_ordinary_member.lock_version, role: "owner"},
               owner_subject
             )

    assert second_owner.role == :owner

    assert {:ok, demoted_original_owner} =
             Conversations.change_member_role(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version, role: "moderator"},
               owner_subject
             )

    assert demoted_original_owner.role == :moderator
  end

  test "tenant administrators retain ownership management for tenant-visible channels" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {_admin, admin_subject} = role_subject_fixture(account, :admin)
    ordinary_member = Fixtures.user_fixture(account).user

    assert {:ok, channel} =
             Conversations.create(
               %{
                 kind: "channel",
                 title: "Tenant-visible ownership",
                 visibility: "tenant",
                 member_ids: [ordinary_member.id]
               },
               owner_subject
             )

    assert {:ok, memberships} = Conversations.list_members(channel.id, owner_subject)
    membership = Enum.find(memberships, &(&1.user.id == ordinary_member.id)).membership

    assert {:ok, promoted} =
             Conversations.change_member_role(
               channel.id,
               ordinary_member.id,
               %{version: membership.lock_version, role: "owner"},
               admin_subject
             )

    assert promoted.role == :owner
  end

  defp role_subject_fixture(account, role) do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-role-password-#{suffix}"
    email = "#{role}-#{suffix}@example.test"

    assert {:ok, user} =
             Accounts.create_user(
               %{
                 display_name: "#{role} #{suffix}",
                 email: email,
                 password: password,
                 role: Atom.to_string(role)
               },
               Fixtures.step_up(account)
             )

    assert {:ok, login} =
             Accounts.authenticate_view(account.tenant.slug, email, password, %{
               name: "#{role} browser",
               platform: "test"
             })

    {:ok, access_context} = Accounts.access_context(login.session_id, "role-test")
    {user, access_context.subject}
  end
end
