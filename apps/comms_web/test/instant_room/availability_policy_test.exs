defmodule CommsWeb.InstantRoom.AvailabilityPolicyTest do
  use CommsWeb.InstantRoomCase

  @moduletag :integration
  @moduletag :conversation

  test "public mutations fail closed before reaching the domain" do
    invalid_auth =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> put_req_header("authorization", "Bearer invalid")
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(invalid_auth, 401)["error"]["code"] == "unauthenticated"

    missing_origin =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", idempotency_key())
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(missing_origin, 403)["error"]["code"] == "origin_required"

    invalid_key =
      build_conn()
      |> public_json_headers("not-a-256-bit-key")
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(invalid_key, 422)["error"]["code"] == "invalid_idempotency_key"

    noncanonical_key =
      build_conn()
      |> public_json_headers(String.duplicate("x", 43))
      |> post("/api/v1/instant-rooms", Jason.encode!(%{display_name: "Guest"}))

    assert json_response(noncanonical_key, 422)["error"]["code"] == "invalid_idempotency_key"
  end

  test "malformed and unavailable join tokens use one indistinguishable response" do
    for token <- ["short", String.duplicate("x", 43)] do
      response =
        build_conn()
        |> public_json_headers()
        |> post("/api/v1/instant-rooms/preview", Jason.encode!(%{token: token}))

      assert json_response(response, 404) == %{
               "error" => %{
                 "code" => "instant_room_unavailable",
                 "detail" => "This instant communication room is unavailable"
               }
             }
    end
  end

  test "feature-off mode fails create, preview, and join closed" do
    Application.put_env(:comms_core, :instant_rooms_enabled, false)
    token = idempotency_key()

    requests = [
      {:create, "/api/v1/instant-rooms", %{display_name: "Disabled"}},
      {:preview, "/api/v1/instant-rooms/preview", %{token: token}},
      {:join, "/api/v1/instant-room-sessions", %{token: token, display_name: "Disabled"}}
    ]

    Enum.each(requests, fn {action, path, body} ->
      conn =
        build_conn()
        |> public_json_headers(if(action in [:create, :join], do: idempotency_key()))
        |> post(path, Jason.encode!(body))

      assert json_response(conn, 503)["error"]["code"] == "instant_rooms_unavailable"
    end)
  end
end
