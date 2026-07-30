defmodule CommsCore.Conversations.DirectoryTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Conversations, Governance, ServiceAccounts}
  alias CommsCore.Accounts.UserView
  alias CommsCore.Conversations.MembershipView
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "conversation membership accepts active service identities and rejects inactive or foreign users" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    suspended = Fixtures.user_fixture(account, %{status: :suspended}).user
    other_account = Fixtures.account_fixture()

    assert {:error, :invalid_members} =
             Conversations.create(
               %{kind: "group", title: "Suspended create", member_ids: [suspended.id]},
               subject
             )

    assert {:error, :invalid_members} =
             Conversations.create(
               %{kind: "group", title: "Foreign create", member_ids: [other_account.user.id]},
               subject
             )

    assert {:error, :invalid_member} =
             Conversations.add_member(
               account.conversation.id,
               suspended.id,
               :member,
               subject
             )

    assert {:error, :invalid_member} =
             Conversations.add_member(
               account.conversation.id,
               other_account.user.id,
               :member,
               subject
             )

    assert {:ok, created_service} =
             ServiceAccounts.create(
               %{
                 name: "Conversation Directory Bot",
                 scopes: ["conversations:read"],
                 reason: "Verify service identity membership"
               },
               subject
             )

    service_user_id = created_service.service_account.user_id

    assert {:ok, service_membership} =
             Conversations.add_member(
               account.conversation.id,
               service_user_id,
               :member,
               subject
             )

    assert service_membership.user_id == service_user_id

    assert {:ok, service_conversation} =
             Conversations.create(
               %{
                 kind: "group",
                 title: "Service-compatible create",
                 member_ids: [service_user_id]
               },
               subject
             )

    assert {:ok, service_members} =
             Conversations.list_member_views(service_conversation.id, subject)

    assert Enum.any?(
             service_members,
             &match?(
               %MembershipView{
                 user_id: ^service_user_id,
                 user: %UserView{account_type: :service}
               },
               &1
             )
           )
  end

  test "member directory returns ordered UserView projections including suspended members" do
    account = Fixtures.account_fixture(%{display_name: "Middle Owner"})
    alpha = Fixtures.user_fixture(account, %{display_name: "Alpha Member"}).user
    zulu = Fixtures.user_fixture(account, %{display_name: "Zulu Member"}).user
    subject = Fixtures.step_up(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 kind: "group",
                 title: "Projected member directory",
                 member_ids: [zulu.id, alpha.id]
               },
               subject
             )

    assert {:ok, %{user: %UserView{status: :suspended}}} =
             Governance.change_user_lifecycle_view(
               zulu.id,
               %{
                 version: zulu.lock_version,
                 status: "suspended",
                 reason: "Verify suspended member projection"
               },
               subject
             )

    assert {:ok, members} = Conversations.list_members(conversation.id, subject)

    assert Enum.map(members, & &1.user.display_name) == [
             "Alpha Member",
             "Middle Owner",
             "Zulu Member"
           ]

    assert Enum.all?(members, &match?(%{user: %UserView{}}, &1))
    assert Enum.find(members, &(&1.user.id == zulu.id)).user.status == :suspended

    assert {:ok, views} = Conversations.list_member_views(conversation.id, subject)
    assert Enum.map(views, & &1.user.display_name) == Enum.map(members, & &1.user.display_name)
    assert Enum.all?(views, &match?(%MembershipView{user: %UserView{}}, &1))
  end

  test "active member ids support delivery fanout without leaking departed or unrelated members" do
    account = Fixtures.account_fixture()
    other_account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    unrelated_member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Delivery fanout",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, _unrelated_conversation} =
             Conversations.create(
               %{
                 title: "Unrelated delivery fanout",
                 kind: "group",
                 visibility: "private",
                 member_ids: [unrelated_member.user.id]
               },
               subject
             )

    expected_ids = Enum.sort([account.user.id, member.user.id])

    assert Conversations.active_member_ids(account.tenant.id, conversation.id) == expected_ids

    assert Conversations.active_member_ids(other_account.tenant.id, conversation.id) == []

    assert {:ok, memberships} = Conversations.list_members(conversation.id, subject)
    member_membership = Enum.find(memberships, &(&1.user.id == member.user.id)).membership

    assert {:ok, _removed} =
             Conversations.remove_member(
               conversation.id,
               member.user.id,
               %{version: member_membership.lock_version},
               subject
             )

    assert Conversations.active_member_ids(account.tenant.id, conversation.id) == [
             account.user.id
           ]
  end
end
