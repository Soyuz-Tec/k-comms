defmodule CommsCore.Notifications.FanoutTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Notifications.Intent
  alias CommsCore.Outbox.Event
  alias CommsCore.{Conversations, Notifications, Repo}
  alias CommsTestSupport.Fixtures

  test "message and mention fanout preserves exclusions, preferences, and idempotency" do
    account = Fixtures.account_fixture()
    ordinary = Fixtures.user_fixture(account).user
    mentioned = Fixtures.user_fixture(account).user
    muted = Fixtures.user_fixture(account).user
    nonmember = Fixtures.user_fixture(account).user
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Notification fanout",
                 kind: "group",
                 visibility: "private",
                 member_ids: [ordinary.id, mentioned.id, muted.id]
               },
               subject
             )

    assert {:ok, _preference} =
             Notifications.update_preferences(
               %{
                 email_enabled: true,
                 push_enabled: false,
                 in_app_enabled: true,
                 muted_event_types: ["message.created.v1"]
               },
               Map.put(subject, :user_id, muted.id)
             )

    message_event =
      event(account, conversation.id, "message.created.v1", %{
        "sender_user_id" => account.user.id,
        "mentioned_user_ids" => [mentioned.id, nonmember.id]
      })

    assert :ok = Notifications.enqueue_for_event(message_event)
    assert :ok = Notifications.enqueue_for_event(message_event)

    assert [{ordinary.id, :email}, {ordinary.id, :in_app}] ==
             intents_for_event(message_event)

    mention_event =
      event(account, conversation.id, "mention.created.v1", %{
        "sender_user_id" => account.user.id,
        "mentioned_user_ids" => [account.user.id, mentioned.id, nonmember.id]
      })

    assert :ok = Notifications.enqueue_for_event(mention_event)

    assert [{mentioned.id, :email}, {mentioned.id, :in_app}] ==
             intents_for_event(mention_event)
  end

  defp event(account, conversation_id, event_type, payload) do
    %Event{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      event_type: event_type,
      aggregate_type: "message",
      aggregate_id: Ecto.UUID.generate(),
      payload: Map.put(payload, "conversation_id", conversation_id)
    }
  end

  defp intents_for_event(event) do
    Intent
    |> Repo.all()
    |> Enum.filter(&(&1.payload["event_id"] == event.id))
    |> Enum.map(&{&1.user_id, &1.channel})
    |> Enum.sort()
  end
end
