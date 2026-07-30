defmodule CommsWeb.InstantRoom.ConversionAndLogoutTest do
  use CommsWeb.InstantRoomCase

  require Phoenix.ChannelTest

  alias CommsCore.Accounts.Session
  alias CommsCore.Conversations

  alias CommsCore.Conversations.{
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestAdmission,
    Membership
  }

  alias CommsCore.Repo

  @moduletag :integration
  @moduletag :conversation
  @moduletag :presence

  test "the creator can upgrade in place and receives a realtime socket handoff" do
    guest =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Future member",
          device: %{name: "Upgrade browser", platform: "web"}
        })
      )
      |> json_response(201)

    socket_ticket =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> post("/api/v1/guest/socket-tickets", %{})
      |> json_response(201)

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{
               "socket_ticket" => socket_ticket["data"]["ticket"]
             })

    session_topic = "session_socket:#{socket.assigns.session_id}"
    assert :ok = CommsWeb.Endpoint.subscribe(session_topic)

    converted =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> post("/api/v1/guest/account", %{
        email: "instant-#{System.unique_integer([:positive])}@example.test",
        password: "correct-instant-room-password-123",
        display_name: "Converted instant member",
        device: %{name: "Upgrade browser", platform: "web"}
      })
      |> json_response(200)

    assert converted["authentication"]["user"]["id"] == guest["user"]["id"]
    assert converted["authentication"]["user"]["account_type"] == "human"
    assert converted["authentication"]["user"]["access_scope"] == "conversation_only"
    assert converted["conversation"]["id"] == guest["conversation"]["id"]
    assert is_binary(converted["socket_handoff"]["ticket"])
    assert is_integer(converted["socket_handoff"]["expires_in"])
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50
  end

  test "ephemeral logout atomically closes only the departing guest scope" do
    host =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Remaining host",
          device: %{name: "Host browser", platform: "web"}
        })
      )
      |> json_response(201)

    joined =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: host["token"],
          display_name: "Departing guest",
          device: %{name: "Guest browser", platform: "web"}
        })
      )
      |> json_response(201)

    assert {:ok, %{context: host_context}} =
             CommsWeb.GuestToken.verify(host["access_token"], "host-presence")

    assert {:ok, %{context: joined_context}} =
             CommsWeb.GuestToken.verify(joined["access_token"], "joined-presence")

    host_presence =
      host_context.subject
      |> Map.put(:conversation_id, host["conversation"]["id"])
      |> Map.put(:connection_id, idempotency_key())

    joined_presence =
      joined_context.subject
      |> Map.put(:conversation_id, host["conversation"]["id"])
      |> Map.put(:connection_id, idempotency_key())

    assert {:ok, host_opened} = Conversations.open_ephemeral_presence(host_presence)
    assert {:ok, joined_opened} = Conversations.open_ephemeral_presence(joined_presence)

    session_topic = "session_socket:#{joined_context.subject.session_id}"
    assert :ok = CommsWeb.Endpoint.subscribe(session_topic)

    assert guest_conn(joined["access_token"])
           |> delete("/api/v1/guest/sessions/current")
           |> response(204)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^session_topic,
      event: "disconnect"
    }

    joined_admission = Repo.get!(GuestAdmission, joined["admission"]["id"])
    assert %GuestAdmission{revoked_at: %DateTime{}} = joined_admission

    assert %Membership{left_at: %DateTime{}} =
             Repo.get!(Membership, joined_admission.membership_id)

    assert %Session{revoked_at: %DateTime{}} =
             Repo.get!(Session, joined_context.subject.session_id)

    assert %EphemeralPresenceLease{closed_at: %DateTime{}} =
             Repo.get!(EphemeralPresenceLease, joined_opened.lease.id)

    host_admission = Repo.get!(GuestAdmission, host["admission"]["id"])
    assert %GuestAdmission{revoked_at: nil} = host_admission

    assert %Membership{left_at: nil} =
             Repo.get!(Membership, host_admission.membership_id)

    assert %Session{revoked_at: nil} =
             Repo.get!(Session, host_context.subject.session_id)

    assert %EphemeralPresenceLease{closed_at: nil} =
             Repo.get!(EphemeralPresenceLease, host_opened.lease.id)

    assert %EphemeralRoom{status: :active} = Repo.get!(EphemeralRoom, host["room"]["id"])

    assert guest_conn(host["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(200)

    assert build_conn()
           |> public_json_headers()
           |> post(
             "/api/v1/instant-rooms/preview",
             Jason.encode!(%{token: host["token"]})
           )
           |> response(200)

    assert guest_conn(joined["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(401)
  end
end
