defmodule CommsWeb.MessageControllerInstantRoomRateLimitTest do
  use CommsWeb.ConnCase, async: false

  import Ecto.Query

  alias CommsCore.PlatformRateLimits.Bucket
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @origin "http://localhost:5173"

  setup do
    account = Fixtures.account_fixture()

    settings = %{
      instant_rooms_enabled: true,
      instant_room_tenant_slug: account.tenant.slug,
      instant_room_guest_idle_ttl_seconds: 3_600,
      instant_room_registered_idle_ttl_seconds: 86_400,
      instant_room_presence_heartbeat_seconds: 30,
      instant_room_presence_lease_seconds: 90,
      instant_room_reconnect_grace_seconds: 90,
      instant_room_max_participants: 5,
      instant_room_message_rate_limit: 1
    }

    previous =
      Map.new(settings, fn {key, _value} ->
        {key, Application.get_env(:comms_core, key)}
      end)

    Enum.each(settings, fn {key, value} ->
      Application.put_env(:comms_core, key, value)
    end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_core, key),
          else: Application.put_env(:comms_core, key, value)
      end)
    end)

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    {:ok, account: account, token: token}
  end

  test "ordinary conversation messages do not consume the instant-room bucket", %{
    account: account,
    token: token
  } do
    for sequence <- 1..2 do
      response =
        token
        |> authenticated_conn()
        |> put_req_header("idempotency-key", "ordinary-message-#{sequence}")
        |> post("/api/v1/conversations/#{account.conversation.id}/messages", %{
          body: "Ordinary message #{sequence}"
        })
        |> json_response(201)

      assert response["data"]["body"] == "Ordinary message #{sequence}"
    end

    assert Repo.aggregate(
             from(bucket in Bucket, where: bucket.scope == "instant_room_message"),
             :count
           ) == 0
  end

  test "a converted instant-room identity is limited on the authenticated REST route" do
    guest = create_guest_room("Future member")

    converted =
      guest["access_token"]
      |> guest_conn()
      |> post("/api/v1/guest/account", %{
        email: "message-limit-#{System.unique_integer([:positive])}@example.test",
        password: "correct-message-limit-password-123",
        display_name: "Converted member",
        device: %{name: "Converted browser", platform: "web"}
      })
      |> json_response(200)

    token = converted["authentication"]["access_token"]
    conversation_id = converted["conversation"]["id"]

    token
    |> authenticated_conn()
    |> put_req_header("idempotency-key", "converted-message-0001")
    |> post("/api/v1/conversations/#{conversation_id}/messages", %{body: "Allowed"})
    |> json_response(201)

    rejected =
      token
      |> authenticated_conn()
      |> put_req_header("idempotency-key", "converted-message-0002")
      |> post("/api/v1/conversations/#{conversation_id}/messages", %{body: "Blocked"})

    assert %{
             "error" => %{
               "code" => "rate_limited",
               "retry_after" => retry_after
             }
           } = json_response(rejected, 429)

    assert retry_after in 1..60
    assert get_resp_header(rejected, "retry-after") == [Integer.to_string(retry_after)]
  end

  test "guest message delegation consumes the shared bucket exactly once" do
    guest = create_guest_room("Guest sender")
    conversation_id = guest["conversation"]["id"]

    allowed =
      guest["access_token"]
      |> guest_conn()
      |> put_req_header("idempotency-key", "guest-shared-limit-0001")
      |> post("/api/v1/guest/conversation/messages", %{body: "Allowed once"})
      |> json_response(201)

    assert allowed["data"]["conversation_id"] == conversation_id
    assert only_message_bucket_count() == 1

    rejected =
      guest["access_token"]
      |> guest_conn()
      |> put_req_header("idempotency-key", "guest-shared-limit-0002")
      |> post("/api/v1/guest/conversation/messages", %{body: "Blocked second"})

    assert %{"error" => %{"code" => "rate_limited"}} = json_response(rejected, 429)
    assert get_resp_header(rejected, "retry-after") != []
    assert only_message_bucket_count() == 2
  end

  defp create_guest_room(display_name) do
    build_conn()
    |> public_json_headers(idempotency_key())
    |> post(
      "/api/v1/instant-rooms",
      Jason.encode!(%{
        display_name: display_name,
        device: %{name: "#{display_name} browser", platform: "web"}
      })
    )
    |> json_response(201)
  end

  defp only_message_bucket_count do
    Repo.one!(
      from(bucket in Bucket,
        where: bucket.scope == "instant_room_message",
        select: bucket.request_count
      )
    )
  end

  defp public_json_headers(conn, idempotency_key) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", @origin)
    |> put_req_header("idempotency-key", idempotency_key)
  end

  defp idempotency_key do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp authenticated_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp guest_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
