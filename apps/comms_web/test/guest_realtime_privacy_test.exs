defmodule CommsWeb.GuestRealtimePrivacyTest do
  use CommsWeb.ConnCase, async: false

  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]
  require Phoenix.ChannelTest

  alias CommsWeb.ConversationChannel
  alias CommsTestSupport.Fixtures

  setup do
    account = Fixtures.account_fixture()
    Fixtures.step_up(account)

    member_token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    {:ok, account: account, member_token: member_token}
  end

  test "guest channels suppress every realtime event for pre-admission messages", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    old_message =
      member_conn(member_token)
      |> put_req_header("idempotency-key", "privacy-old-message-0001")
      |> post("/api/v1/conversations/#{conversation_id}/messages", %{body: "Before guest"})
      |> json_response(201)
      |> Map.fetch!("data")

    %{guest: guest, socket: socket} =
      redeem_and_join_guest(account, member_token, "Realtime Privacy Guest")

    assert guest["admission"]["history_from_sequence"] > old_message["conversation_sequence"]

    pre_admission_events = [
      {"message.created.v1", old_message},
      {"message.updated.v1", Map.put(old_message, "body", "Still private")},
      {"message.deleted.v1", Map.put(old_message, "status", "deleted")},
      {"message.reaction_added.v1",
       %{message_id: old_message["id"], emoji: "👍", user_id: account.user.id}},
      {"message.reaction_removed.v1",
       %{message_id: old_message["id"], emoji: "👍", user_id: account.user.id}}
    ]

    Enum.each(pre_admission_events, fn {event, payload} ->
      CommsWeb.Broadcast.event(conversation_id, event, payload)
      refute_push(^event, _payload, 75)
    end)

    new_message =
      member_conn(member_token)
      |> put_req_header("idempotency-key", "privacy-new-message-0001")
      |> post("/api/v1/conversations/#{conversation_id}/messages", %{body: "Visible to guest"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert_push("message.created.v1", %{id: new_message_id})
    assert new_message_id == new_message["id"]

    CommsWeb.Broadcast.event(conversation_id, "message.reaction_added.v1", %{
      message_id: new_message["id"],
      emoji: "✅",
      user_id: account.user.id
    })

    assert_push("message.reaction_added.v1", %{message_id: visible_message_id})
    assert visible_message_id == new_message["id"]

    # Keep the joined socket live through every suppressed event.
    assert Process.alive?(socket.channel_pid)
  end

  test "call lifecycle events reauthorize guests and explicit link revocation disconnects sessions",
       %{
         account: account,
         member_token: member_token
       } do
    %{guest: _guest, link: link, socket: socket} =
      redeem_and_join_guest(account, member_token, "Revoked Realtime Guest")

    session_id = socket.assigns.session_id
    session_topic = "session_socket:#{session_id}"
    assert is_binary(session_id)
    assert :ok = CommsWeb.Endpoint.subscribe(session_topic)

    expired_socket = %{
      socket
      | assigns:
          Map.put(
            socket.assigns,
            :guest_expires_at,
            DateTime.utc_now() |> DateTime.add(-1, :second)
          )
    }

    call_events = [
      "call.started.v1",
      "call.ended.v1",
      "audio_call.started.v1",
      "audio_call.ended.v1"
    ]

    Enum.each(call_events, fn event ->
      assert {:stop, :unauthorized, ^expired_socket} =
               ConversationChannel.handle_out(event, %{id: Ecto.UUID.generate()}, expired_socket)
    end)

    assert {:stop, :unauthorized, ^expired_socket} =
             ConversationChannel.handle_info(:guest_access_expired, expired_socket)

    revoked =
      member_conn(member_token)
      |> delete(
        "/api/v1/conversations/#{account.conversation.id}/guest-links/#{link["data"]["id"]}"
      )
      |> json_response(200)

    assert revoked["data"]["status"] == "revoked"

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^session_topic,
      event: "disconnect",
      payload: %{}
    }

    Enum.each(call_events, fn event ->
      assert {:stop, :unauthorized, ^socket} =
               ConversationChannel.handle_out(event, %{id: Ecto.UUID.generate()}, socket)
    end)
  end

  defp redeem_and_join_guest(account, member_token, display_name) do
    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{account.conversation.id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: display_name,
        device: %{name: "Guest privacy browser", platform: "test"}
      })
      |> json_response(201)

    socket_ticket =
      guest_conn(guest["access_token"])
      |> post("/api/v1/guest/socket-tickets", %{})
      |> json_response(201)

    assert {:ok, connected_socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{
               "socket_ticket" => socket_ticket["data"]["ticket"]
             })

    assert {:ok, _reply, socket} =
             subscribe_and_join(
               connected_socket,
               ConversationChannel,
               "conversation:#{account.conversation.id}",
               %{"after_sequence" => 0}
             )

    %{guest: guest, link: link, socket: socket}
  end

  defp member_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp guest_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
