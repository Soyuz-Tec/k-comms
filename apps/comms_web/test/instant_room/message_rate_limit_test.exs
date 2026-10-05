defmodule CommsWeb.InstantRoom.MessageRateLimitTest do
  use CommsWeb.InstantRoomCase

  alias CommsCore.Repo
  alias Ecto.Adapters.SQL

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

    window_start = 600_000_000
    install_database_clock(window_start + 59)

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

    set_database_clock(window_start + 60)

    accepted =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> put_req_header("idempotency-key", "instant-http-message-0002")
      |> post("/api/v1/guest/conversation/messages", %{body: "new window"})

    assert %{"data" => %{"body" => "new window", "conversation_sequence" => 1}} =
             json_response(accepted, 201)
  end

  defp install_database_clock(epoch_second) do
    # Keep the exhausted bucket in its own sandbox-local calendar window.
    # Transaction rollback removes this function and search_path override;
    # production admission still uses PostgreSQL's real clock.
    schema = "instant_http_rate_clock_#{System.unique_integer([:positive, :monotonic])}"
    SQL.query!(Repo, "CREATE SCHEMA #{schema}", [])

    SQL.query!(
      Repo,
      """
      CREATE FUNCTION #{schema}.clock_timestamp() RETURNS timestamp with time zone
      LANGUAGE sql VOLATILE AS $$
        SELECT pg_catalog.to_timestamp(
          pg_catalog.current_setting('k_comms.test_rate_limit_epoch')::bigint
        )
      $$
      """,
      []
    )

    SQL.query!(Repo, "SET LOCAL search_path TO #{schema}, public, pg_catalog", [])
    set_database_clock(epoch_second)
  end

  defp set_database_clock(epoch_second) do
    SQL.query!(
      Repo,
      "SELECT pg_catalog.set_config('k_comms.test_rate_limit_epoch', $1, true)",
      [Integer.to_string(epoch_second)]
    )

    assert [[^epoch_second]] =
             SQL.query!(
               Repo,
               "SELECT floor(extract(epoch FROM clock_timestamp()))::bigint",
               []
             ).rows
  end
end
