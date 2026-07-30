defmodule CommsCore.Conversations.CommandsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Conversations
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "creates a group and advances the read cursor monotonically" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Product",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, result} = Conversations.get_for_user(conversation.id, subject)
    assert result.membership_role == :owner
    assert {:ok, 0} = Conversations.mark_read(conversation.id, 10, subject)
    assert {:ok, 0} = Conversations.mark_read(conversation.id, 0, subject)

    assert {:ok, members} = Conversations.list_members(conversation.id, subject)
    assert length(members) == 2
  end

  test "updates and archives channels with versioned membership ownership" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Operations",
                 kind: "channel",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, updated} =
             Conversations.update(
               conversation.id,
               %{
                 version: conversation.lock_version,
                 title: "Operations team",
                 visibility: "tenant"
               },
               subject
             )

    assert updated.title == "Operations team"
    assert updated.visibility == :tenant

    assert Enum.any?(
             Conversations.list_for_user(subject),
             &(&1.conversation.id == conversation.id)
           )

    assert {:error, :stale_version} =
             Conversations.update(conversation.id, %{version: 1, title: "Stale"}, subject)

    assert {:ok, members} = Conversations.list_members(conversation.id, subject)
    member_membership = Enum.find(members, &(&1.user.id == member.user.id)).membership
    owner_membership = Enum.find(members, &(&1.user.id == account.user.id)).membership

    assert {:ok, promoted} =
             Conversations.change_member_role(
               conversation.id,
               member.user.id,
               %{version: member_membership.lock_version, role: "owner"},
               subject
             )

    assert promoted.role == :owner

    assert {:ok, demoted} =
             Conversations.change_member_role(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version, role: "moderator"},
               subject
             )

    assert demoted.role == :moderator

    assert {:ok, archived} =
             Conversations.archive(conversation.id, %{version: updated.lock_version}, subject)

    assert archived.archived_at

    refute Enum.any?(
             Conversations.list_for_user(subject),
             &(&1.conversation.id == conversation.id)
           )

    assert {:error, :not_found} =
             Conversations.update(
               conversation.id,
               %{version: archived.lock_version, title: "No"},
               subject
             )
  end
end
