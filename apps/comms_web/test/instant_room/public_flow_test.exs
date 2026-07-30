defmodule CommsWeb.InstantRoom.PublicFlowTest do
  use CommsWeb.InstantRoomCase

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "anonymous creation, replay, preview, and guest join form a complete public flow", %{
    account: _account
  } do
    public_share_origin = "https://comms.avayaworks.com"
    previous_share_origin = Application.fetch_env!(:comms_web, :public_share_origin)
    Application.put_env(:comms_web, :public_share_origin, public_share_origin)

    on_exit(fn ->
      Application.put_env(:comms_web, :public_share_origin, previous_share_origin)
    end)

    create_key = idempotency_key()

    create_body = %{
      display_name: "Instant host",
      title: "Customer room",
      device: %{name: "Host browser", platform: "web"}
    }

    created =
      build_conn()
      |> public_json_headers(create_key)
      |> post("/api/v1/instant-rooms", Jason.encode!(create_body))

    assert get_resp_header(created, "cache-control") == ["no-store"]

    response = json_response(created, 201)
    assert response["replayed"] == false
    assert response["room"]["status"] == "active"
    assert response["room"]["owner_kind"] == "guest"
    assert response["room"]["conversation_id"] == response["conversation"]["id"]

    assert Map.keys(response["room"]) |> Enum.sort() ==
             ~w(conversation_id expires_at id idle_since inserted_at owner_kind owner_user_id participant_limit status updated_at)

    refute Map.has_key?(response["room"], "generation")
    refute Map.has_key?(response["room"], "reconnect_grace_seconds")
    refute Map.has_key?(response["room"], "last_presence_at")
    assert response["user"]["account_type"] == "guest"
    assert response["user"]["access_scope"] == "conversation_only"
    assert response["capabilities"]["self_service_conversion"] == true
    assert is_binary(response["access_token"])
    assert is_binary(response["refresh_token"])
    assert is_binary(response["token"])

    assert response["share_url"] ==
             "#{public_share_origin}/join#guest=#{URI.encode_www_form(response["token"])}"

    refute response["share_url"] =~ "?token="

    replayed =
      build_conn()
      |> public_json_headers(create_key)
      |> post("/api/v1/instant-rooms", Jason.encode!(create_body))
      |> json_response(200)

    assert replayed["replayed"] == true
    assert replayed["room"]["id"] == response["room"]["id"]
    assert replayed["conversation"]["id"] == response["conversation"]["id"]

    preview =
      build_conn()
      |> public_json_headers()
      |> post(
        "/api/v1/instant-rooms/preview",
        Jason.encode!(%{token: response["token"]})
      )
      |> json_response(200)

    assert preview["data"]["room_title"] == "Customer room"
    assert preview["data"]["status"] == "active"

    assert Map.keys(preview["data"]) |> Enum.sort() ==
             ~w(expires_at participant_limit room_title status)

    conversation_topic = "conversation:#{response["conversation"]["id"]}"
    assert :ok = CommsWeb.Endpoint.subscribe(conversation_topic)
    join_key = idempotency_key()

    joined =
      build_conn()
      |> public_json_headers(join_key)
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: response["token"],
          display_name: "Instant guest",
          device: %{name: "Guest browser", platform: "web"}
        })
      )
      |> json_response(201)

    assert joined["room"]["id"] == response["room"]["id"]
    assert joined["conversation"]["id"] == response["conversation"]["id"]
    assert joined["user"]["account_type"] == "guest"
    assert joined["user"]["access_scope"] == "conversation_only"
    assert joined["user"]["id"] != response["user"]["id"]
    assert joined["capabilities"]["self_service_conversion"] == true

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^conversation_topic,
      event: "membership.changed.v1",
      payload: %{
        user_id: joined_user_id,
        action: "added",
        role: :member,
        source: "guest_link"
      }
    }

    assert joined_user_id == joined["user"]["id"]
    refute_received %Phoenix.Socket.Broadcast{topic: ^conversation_topic}

    replayed_join =
      build_conn()
      |> public_json_headers(join_key)
      |> post(
        "/api/v1/instant-room-sessions",
        Jason.encode!(%{
          token: response["token"],
          display_name: "Instant guest",
          device: %{name: "Guest browser", platform: "web"}
        })
      )
      |> json_response(200)

    assert replayed_join["replayed"] == true
    assert replayed_join["user"]["id"] == joined["user"]["id"]
    refute_receive %Phoenix.Socket.Broadcast{topic: ^conversation_topic}, 50

    refreshed =
      build_conn()
      |> post("/api/v1/guest/sessions/refresh", %{
        refresh_token: replayed_join["refresh_token"]
      })
      |> json_response(200)

    assert refreshed["user"]["id"] == joined["user"]["id"]
    assert refreshed["conversation"]["id"] == joined["conversation"]["id"]
    assert refreshed["capabilities"]["self_service_conversion"] == true
  end

  test "human creation preserves existing authentication", %{account: account} do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    response =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{title: "Registered host room"})
      )
      |> json_response(201)

    assert response["room"]["owner_kind"] == "registered"
    assert response["conversation"]["id"] == response["room"]["conversation_id"]
    assert is_binary(response["share_url"])
    refute Map.has_key?(response, "access_token")
    refute Map.has_key?(response, "refresh_token")
  end

  test "anonymous creation rejects a missing display name" do
    response =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{device: %{name: "Host browser", platform: "web"}})
      )

    assert json_response(response, 422)["error"]["code"] == "invalid_guest_display_name"
  end
end
