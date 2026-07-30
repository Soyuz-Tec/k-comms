defmodule CommsWeb.InstantRoom.MessageRateLimitTest do
  use CommsWeb.InstantRoomCase

  @moduletag :integration
  @moduletag :conversation
  @moduletag :messaging

  test "HTTP messages share the per-identity instant-room distributed limit" do
    guest =
      build_conn()
      |> public_json_headers(idempotency_key())
      |> post(
        "/api/v1/instant-rooms",
        Jason.encode!(%{
          display_name: "Rate limited guest",
          device: %{name: "Rate browser", platform: "web"}
        })
      )
      |> json_response(201)

    assert {:ok, %{context: context}} =
             CommsWeb.GuestToken.verify(guest["access_token"], "rate-limit-test")

    key_digest =
      CommsWeb.Plugs.DistributedRateLimit.key_digest(:instant_room_message, [
        "identity-room",
        0,
        context.subject.tenant_id,
        0,
        context.subject.user_id,
        0,
        context.subject.session_id,
        0,
        guest["conversation"]["id"]
      ])

    for _request <- 1..30 do
      assert %{allowed: true} =
               CommsCore.PlatformRateLimits.allow?(
                 :instant_room_message,
                 key_digest,
                 30,
                 60
               )
    end

    rejected =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> put_req_header("idempotency-key", "instant-http-message-0001")
      |> post("/api/v1/guest/conversation/messages", %{body: "blocked"})

    assert %{
             "error" => %{
               "code" => "rate_limited",
               "retry_after" => retry_after
             }
           } = json_response(rejected, 429)

    assert retry_after in 1..60
    assert get_resp_header(rejected, "retry-after") == [Integer.to_string(retry_after)]
  end
end
