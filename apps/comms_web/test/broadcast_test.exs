defmodule CommsWeb.BroadcastTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Conversations
  alias CommsTestSupport.Fixtures
  alias CommsWeb.Broadcast

  test "conversation fanout reaches only active members" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    unrelated_member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Broadcast fanout",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    owner_id = account.user.id
    member_id = member.user.id
    unrelated_id = unrelated_member.user.id
    owner_topic = "user:#{owner_id}"
    member_topic = "user:#{member_id}"
    unrelated_topic = "user:#{unrelated_id}"

    for topic <- [owner_topic, member_topic, unrelated_topic] do
      assert :ok = CommsWeb.Endpoint.subscribe(topic)
    end

    assert :ok = Broadcast.conversation_activity(conversation.id, 41, "message.created.v1")

    expected_activity = %{
      conversation_id: conversation.id,
      latest_sequence: 41,
      event_type: "message.created.v1"
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^owner_topic,
      event: "conversation.activity.v1",
      payload: ^expected_activity
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^member_topic,
      event: "conversation.activity.v1",
      payload: ^expected_activity
    }

    refute_receive %Phoenix.Socket.Broadcast{
      topic: ^unrelated_topic,
      event: "conversation.activity.v1"
    }

    assert {:ok, memberships} = Conversations.list_members(conversation.id, subject)
    membership = Enum.find(memberships, &(&1.user.id == member.user.id)).membership

    assert {:ok, _removed} =
             Conversations.remove_member(
               conversation.id,
               member.user.id,
               %{version: membership.lock_version},
               subject
             )

    assert :ok = Broadcast.conversation_memberships(conversation.id, "removed")

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^owner_topic,
      event: "conversation.membership.v1",
      payload: %{conversation_id: conversation_id, action: "removed"}
    }

    assert conversation_id == conversation.id

    refute_receive %Phoenix.Socket.Broadcast{
      topic: ^member_topic,
      event: "conversation.membership.v1"
    }

    refute_receive %Phoenix.Socket.Broadcast{
      topic: ^unrelated_topic,
      event: "conversation.membership.v1"
    }
  end
end
