defmodule CommsCore.ConversationsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Conversations
  alias CommsTestSupport.Fixtures

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
end
