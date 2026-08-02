defmodule CommsWeb.InstantRoom.WhiteboardCollaborationTest do
  use CommsWeb.InstantRoomCase

  import Phoenix.ChannelTest

  alias CommsTestSupport.Fixtures

  @endpoint CommsWeb.Endpoint
  @moduletag :integration
  @moduletag :whiteboard
  @moduletag :guest

  test "instant-room guests share durable whiteboard history and realtime presence", %{
    account: _account
  } do
    created =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post("/api/v1/instant-rooms", %{
        display_name: "Canvas host",
        title: "Shared canvas",
        device: %{name: "Host browser", platform: "web"}
      })
      |> json_response(201)

    host_token = created["access_token"]
    conversation_id = created["conversation"]["id"]
    operation_path = "/api/v1/guest/conversation/whiteboard/operations"

    host_operation =
      guest_conn(host_token)
      |> put_req_header("idempotency-key", "instant-whiteboard-host-operation")
      |> post(operation_path, %{
        conversation_id: Ecto.UUID.generate(),
        kind: "scene.update",
        base_sequence: 0,
        payload: %{elements: [element("host-note", 1, 41)]}
      })
      |> json_response(201)

    assert host_operation["data"]["conversation_id"] == conversation_id
    assert host_operation["data"]["sequence"] == 1

    joined =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post("/api/v1/instant-room-sessions", %{
        token: created["token"],
        display_name: "Canvas guest",
        device: %{name: "Guest browser", platform: "web"}
      })
      |> json_response(201)

    guest_token = joined["access_token"]

    history =
      guest_conn(guest_token)
      |> get("#{operation_path}?after_sequence=0")
      |> json_response(200)

    assert Enum.map(history["data"], & &1["id"]) == [host_operation["data"]["id"]]

    guest_operation =
      guest_conn(guest_token)
      |> put_req_header("idempotency-key", "instant-whiteboard-guest-operation")
      |> post(operation_path, %{
        kind: "scene.update",
        base_sequence: 1,
        payload: %{elements: [element("guest-note", 1, 73)]}
      })
      |> json_response(201)

    assert guest_operation["data"]["sequence"] == 2

    ticket =
      guest_conn(guest_token)
      |> post("/api/v1/guest/socket-tickets", %{})
      |> json_response(201)

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{
               "socket_ticket" => ticket["data"]["ticket"]
             })

    assert {:ok, %{}, _socket} =
             subscribe_and_join(
               socket,
               CommsWeb.WhiteboardChannel,
               "whiteboard:#{conversation_id}",
               %{"protocol_version" => 1}
             )
  end

  test "ordinary conversation guest links do not gain whiteboard access", %{
    account: account
  } do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    link =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(
        "/api/v1/conversations/#{account.conversation.id}/guest-links",
        %{expires_in_seconds: 900, max_uses: 1}
      )
      |> json_response(201)

    session =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "Bounded guest",
        device: %{name: "Guest browser", platform: "web"}
      })
      |> json_response(201)

    guest_conn(session["access_token"])
    |> get("/api/v1/guest/conversation/whiteboard/operations")
    |> json_response(403)
  end

  test "instant-room whiteboard writes use a per-identity distributed limit" do
    previous_limit =
      Application.get_env(:comms_core, :instant_room_whiteboard_rate_limit)

    Application.put_env(:comms_core, :instant_room_whiteboard_rate_limit, 1)

    on_exit(fn ->
      if is_nil(previous_limit) do
        Application.delete_env(:comms_core, :instant_room_whiteboard_rate_limit)
      else
        Application.put_env(
          :comms_core,
          :instant_room_whiteboard_rate_limit,
          previous_limit
        )
      end
    end)

    guest =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post("/api/v1/instant-rooms", %{
        display_name: "Canvas rate test",
        device: %{name: "Rate browser", platform: "web"}
      })
      |> json_response(201)

    operation_path = "/api/v1/guest/conversation/whiteboard/operations"

    guest["access_token"]
    |> guest_conn()
    |> put_req_header("idempotency-key", "instant-whiteboard-rate-0001")
    |> post(operation_path, %{
      kind: "scene.update",
      base_sequence: 0,
      payload: %{elements: [element("allowed-shape", 1, 101)]}
    })
    |> json_response(201)

    rejected =
      guest["access_token"]
      |> guest_conn()
      |> put_req_header("idempotency-key", "instant-whiteboard-rate-0002")
      |> post(operation_path, %{
        kind: "scene.update",
        base_sequence: 1,
        payload: %{elements: [element("blocked-shape", 1, 102)]}
      })

    assert %{
             "error" => %{
               "code" => "rate_limited",
               "retry_after" => retry_after
             }
           } = json_response(rejected, 429)

    assert retry_after in 1..60
    assert get_resp_header(rejected, "retry-after") == [Integer.to_string(retry_after)]
  end

  defp element(id, version, nonce) do
    %{
      id: id,
      type: "rectangle",
      version: version,
      versionNonce: nonce,
      link: nil,
      customData: nil,
      x: 10,
      y: 20,
      width: 100,
      height: 80,
      isDeleted: false
    }
  end
end
