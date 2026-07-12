defmodule CommsWeb.InAppNotificationControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Notifications.Intent
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Notifications
  alias CommsCore.Notifications.Preference
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "users list, read, dismiss, and bulk-read their in-app notifications" do
    account = Fixtures.account_fixture()
    token = CommsWeb.Token.issue(account).access_token

    first = insert_intent(account, "mention.created.v1", "https://evil.example/leave")
    second = insert_intent(account, "message.created.v1", "/app?conversation=safe")
    admin_path = insert_intent(account, "message.created.v1", "/admin")

    listed =
      authenticated_conn(token)
      |> get("/api/v1/in-app-notifications")
      |> json_response(200)

    assert listed["meta"]["unread_count"] == 3

    assert Enum.map(listed["data"], & &1["id"]) |> MapSet.new() ==
             MapSet.new([first.id, second.id, admin_path.id])

    mention = Enum.find(listed["data"], &(&1["id"] == first.id))
    assert mention["title"] == "New mention"
    assert mention["action_url"] == nil
    refute Map.has_key?(mention, "payload")

    safe = Enum.find(listed["data"], &(&1["id"] == second.id))
    assert safe["action_url"] == "/app?conversation=safe"

    restricted = Enum.find(listed["data"], &(&1["id"] == admin_path.id))
    assert restricted["action_url"] == nil

    read =
      authenticated_conn(token)
      |> patch("/api/v1/in-app-notifications/#{first.id}/read")
      |> json_response(200)

    assert read["data"]["read_at"]

    dismissed =
      authenticated_conn(token)
      |> delete("/api/v1/in-app-notifications/#{first.id}")
      |> json_response(200)

    assert dismissed["data"]["id"] == first.id

    count =
      authenticated_conn(token)
      |> get("/api/v1/in-app-notifications/unread-count")
      |> json_response(200)

    assert count["data"]["unread_count"] == 2

    bulk =
      authenticated_conn(token)
      |> post("/api/v1/in-app-notifications/read-all")
      |> json_response(200)

    assert bulk["data"] == %{"unread_count" => 0, "updated_count" => 2}

    remaining =
      authenticated_conn(token)
      |> get("/api/v1/in-app-notifications")
      |> json_response(200)

    assert Enum.map(remaining["data"], & &1["id"]) |> MapSet.new() ==
             MapSet.new([second.id, admin_path.id])
  end

  test "new in-app intents emit only content-free user availability metadata" do
    account = Fixtures.account_fixture()
    event_id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()
    :ok = CommsWeb.Endpoint.subscribe("user:#{account.user.id}")

    event = %OutboxEvent{
      id: event_id,
      tenant_id: account.tenant.id,
      event_type: "mention.created.v1",
      aggregate_type: "message",
      aggregate_id: message_id,
      payload: %{
        "conversation_id" => account.conversation.id,
        "sender_user_id" => Ecto.UUID.generate()
      }
    }

    preference = %Preference{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      email_enabled: false,
      push_enabled: false,
      in_app_enabled: true,
      muted_event_types: []
    }

    assert :ok = Notifications.enqueue_recipient_event(event, account.user, preference)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "notification.available.v1",
      payload: payload
    }

    assert payload.notification_id
    assert payload.event_type == "mention.created.v1"
    assert payload.conversation_id == account.conversation.id
    assert payload.message_id == message_id
    assert payload.unread_count == 1
    refute Map.has_key?(payload, :title)
    refute Map.has_key?(payload, :body)
  end

  defp insert_intent(account, event_type, action_url) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Intent{}
    |> Intent.changeset(%{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      event_type: event_type,
      channel: :in_app,
      destination: account.user.id,
      payload: %{
        "action_url" => action_url,
        "conversation_id" => account.conversation.id,
        "message_id" => Ecto.UUID.generate()
      },
      idempotency_key: "in-app-controller:#{Ecto.UUID.generate()}",
      status: :delivered,
      next_attempt_at: timestamp,
      delivered_at: timestamp
    })
    |> Repo.insert!()
  end

  defp authenticated_conn(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end
end
