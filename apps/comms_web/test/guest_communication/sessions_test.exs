defmodule CommsWeb.GuestCommunication.SessionsTest do
  use CommsWeb.ConnCase, async: false

  require Phoenix.ChannelTest

  import CommsWeb.GuestCommunicationTestSupport

  @moduletag :integration
  @moduletag :guest

  setup :setup_account

  test "one-time link preview and redemption create a strictly room-scoped guest session", %{
    account: account,
    member_token: member_token
  } do
    public_share_origin = "https://comms.avayaworks.com"
    previous_share_origin = Application.fetch_env!(:comms_web, :public_share_origin)
    Application.put_env(:comms_web, :public_share_origin, public_share_origin)

    on_exit(fn ->
      Application.put_env(:comms_web, :public_share_origin, previous_share_origin)
    end)

    fixture = communication_fixture(account, member_token, old_message: true)
    conversation_id = fixture.conversation_id
    link = fixture.link
    old_message = fixture.old_message
    session = fixture.session

    assert link["data"]["conversation_id"] == conversation_id
    assert link["data"]["remaining_uses"] == 2

    assert link["data"]["share_url"] ==
             "#{public_share_origin}/join#guest=#{URI.encode_www_form(link["token"])}"

    assert link["share_url"] == link["data"]["share_url"]
    assert is_binary(link["token"])
    refute Map.has_key?(link, "conversion_verification_code")
    refute link["data"]["share_url"] =~ "code="

    preview =
      build_conn()
      |> post("/api/v1/guest-links/preview", %{token: link["token"]})
      |> json_response(200)

    assert preview == %{
             "data" => %{
               "room_title" => "General",
               "expires_at" => link["data"]["expires_at"],
               "conversion_enabled" => false,
               "email_hint" => nil
             }
           }

    refute inspect(preview) =~ account.tenant.id
    refute inspect(preview) =~ conversation_id

    assert session["user"]["account_type"] == "guest"
    assert session["user"]["display_name"] == "External Guest"
    refute Map.has_key?(session["user"], "email")
    assert session["conversation"]["id"] == conversation_id
    assert session["admission"]["guest_link_id"] == link["data"]["id"]

    assert session["admission"]["history_from_sequence"] >
             old_message["data"]["conversation_sequence"]

    assert session["capabilities"]["self_service_conversion"] == false
    assert is_binary(session["access_token"])
    assert is_binary(session["refresh_token"])

    guest_token = session["access_token"]

    assert member_conn(member_token)
           |> get("/api/v1/guest/conversation")
           |> response(401)

    assert guest_conn(guest_token) |> get("/api/v1/me") |> response(401)

    room =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation")
      |> json_response(200)

    assert room["data"]["id"] == conversation_id

    active_call =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation/call")
      |> json_response(200)

    assert active_call["data"] == nil

    members =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation/members")
      |> json_response(200)

    assert Enum.any?(members["data"], &(&1["user"]["id"] == session["user"]["id"]))

    assert Enum.all?(members["data"], fn membership ->
             Map.keys(membership["user"]) |> Enum.sort() ==
               ~w(account_type display_name id role status)
           end)
  end

  @tag :messaging
  test "guest messaging routes enforce room scope and the admission history boundary", %{
    account: account,
    member_token: member_token
  } do
    fixture = communication_fixture(account, member_token, old_message: true)
    conversation_id = fixture.conversation_id
    old_message = fixture.old_message
    session = fixture.session
    guest_token = session["access_token"]

    history =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation/messages?after_sequence=0")
      |> json_response(200)

    refute Enum.any?(history["data"], &(&1["id"] == old_message["data"]["id"]))

    substituted_conversation_id = Ecto.UUID.generate()

    sent =
      guest_conn(guest_token)
      |> put_req_header(
        "idempotency-key",
        "guest-message-send-#{System.unique_integer([:positive, :monotonic])}"
      )
      |> post("/api/v1/guest/conversation/messages", %{
        body: "Hello from the guest",
        conversation_id: substituted_conversation_id,
        tenant_id: Ecto.UUID.generate(),
        sender_user_id: Ecto.UUID.generate()
      })
      |> json_response(201)

    assert sent["data"]["conversation_id"] == conversation_id
    assert sent["data"]["sender_user_id"] == session["user"]["id"]

    history_with_labels =
      guest_conn(guest_token)
      |> get("/api/v1/guest/conversation/messages?after_sequence=0&include=sender_labels")
      |> json_response(200)

    assert Enum.any?(history_with_labels["data"], &(&1["id"] == sent["data"]["id"]))

    assert history_with_labels["included"]["sender_labels"] == [
             %{
               "id" => session["user"]["id"],
               "display_name" => "External Guest",
               "redacted" => false
             }
           ]

    refreshed_labels =
      guest_conn(guest_token)
      |> post("/api/v1/guest/conversation/message-sender-labels", %{
        message_ids: [
          old_message["data"]["id"],
          sent["data"]["id"],
          Ecto.UUID.generate()
        ],
        conversation_id: substituted_conversation_id
      })
      |> json_response(200)

    assert refreshed_labels["data"] == history_with_labels["included"]["sender_labels"]

    assert guest_conn(guest_token)
           |> post("/api/v1/guest/conversation/message-sender-labels", %{
             message_ids: [sent["data"]["id"], sent["data"]["id"]]
           })
           |> response(422)

    cursor =
      guest_conn(guest_token)
      |> put("/api/v1/guest/conversation/read-cursor", %{
        sequence: sent["data"]["conversation_sequence"],
        conversation_id: substituted_conversation_id
      })
      |> json_response(200)

    assert cursor["data"]["sequence"] == sent["data"]["conversation_sequence"]
  end

  @tag :messaging
  test "guest realtime access is restricted to the admitted conversation and history", %{
    account: account,
    member_token: member_token
  } do
    fixture = communication_fixture(account, member_token, old_message: true)
    conversation_id = fixture.conversation_id
    old_message = fixture.old_message
    session = fixture.session
    guest_token = session["access_token"]

    sent =
      guest_conn(guest_token)
      |> put_req_header(
        "idempotency-key",
        "guest-channel-message-#{System.unique_integer([:positive, :monotonic])}"
      )
      |> post("/api/v1/guest/conversation/messages", %{body: "Visible after admission"})
      |> json_response(201)

    socket_ticket =
      guest_conn(guest_token)
      |> post("/api/v1/guest/socket-tickets", %{})
      |> json_response(201)

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{
               "socket_ticket" => socket_ticket["data"]["ticket"]
             })

    assert socket.assigns.account_type == :guest
    assert socket.assigns.guest_conversation_id == conversation_id
    assert socket.assigns.guest_admission_id == session["admission"]["id"]

    assert {:error, %{reason: "forbidden"}} =
             CommsWeb.UserChannel.join("user:#{session["user"]["id"]}", %{}, socket)

    assert {:error, %{reason: "forbidden"}} =
             CommsWeb.ConversationChannel.join(
               "conversation:#{Ecto.UUID.generate()}",
               %{},
               socket
             )

    assert {:ok, replay, _socket} =
             CommsWeb.ConversationChannel.join(
               "conversation:#{conversation_id}",
               %{"after_sequence" => 0},
               socket
             )

    refute Enum.any?(replay.messages, &(&1.id == old_message["data"]["id"]))
    assert Enum.any?(replay.messages, &(&1.id == sent["data"]["id"]))

    expired_socket = %{
      socket
      | assigns:
          Map.put(
            socket.assigns,
            :guest_expires_at,
            DateTime.utc_now() |> DateTime.add(-1, :second)
          )
    }

    assert {:error, %{reason: "forbidden"}} =
             CommsWeb.ConversationChannel.join(
               "conversation:#{conversation_id}",
               %{},
               expired_socket
             )
  end

  @tag :messaging
  test "refresh and logout terminate guest access while retaining attributed history", %{
    account: account,
    member_token: member_token
  } do
    fixture = communication_fixture(account, member_token)
    conversation_id = fixture.conversation_id
    link = fixture.link
    session = fixture.session

    sent =
      guest_conn(session["access_token"])
      |> put_req_header(
        "idempotency-key",
        "guest-retained-message-#{System.unique_integer([:positive, :monotonic])}"
      )
      |> post("/api/v1/guest/conversation/messages", %{body: "Retained guest history"})
      |> json_response(201)

    refreshed =
      build_conn()
      |> post("/api/v1/guest/sessions/refresh", %{refresh_token: session["refresh_token"]})
      |> json_response(200)

    assert refreshed["conversation"]["id"] == conversation_id
    assert refreshed["user"]["id"] == session["user"]["id"]
    assert refreshed["admission"]["guest_link_id"] == link["data"]["id"]
    assert refreshed["capabilities"]["self_service_conversion"] == false
    assert is_binary(refreshed["access_token"])
    assert refreshed["refresh_token"] != session["refresh_token"]

    assert :ok = CommsWeb.Endpoint.subscribe("conversation:#{conversation_id}")

    assert guest_conn(refreshed["access_token"])
           |> delete("/api/v1/guest/sessions/current")
           |> response(204)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "conversation:" <> ^conversation_id,
      event: "membership.changed.v1",
      payload: %{
        user_id: guest_user_id,
        action: "removed",
        source: "guest_link"
      }
    }

    assert guest_user_id == session["user"]["id"]

    retained_history =
      member_conn(member_token)
      |> get(
        "/api/v1/conversations/#{conversation_id}/messages?after_sequence=0&include=sender_labels"
      )
      |> json_response(200)

    assert Enum.any?(retained_history["data"], &(&1["id"] == sent["data"]["id"]))

    assert Enum.any?(
             retained_history["included"]["sender_labels"],
             &(&1 == %{
                 "id" => session["user"]["id"],
                 "display_name" => "External Guest",
                 "redacted" => false
               })
           )

    active_members =
      member_conn(member_token)
      |> get("/api/v1/conversations/#{conversation_id}/members")
      |> json_response(200)

    refute Enum.any?(active_members["data"], &(&1["user"]["id"] == session["user"]["id"]))

    assert guest_conn(refreshed["access_token"])
           |> get("/api/v1/guest/conversation")
           |> response(401)
  end
end
