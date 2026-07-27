defmodule CommsWeb.DistributedRateLimitTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.PlatformRateLimits
  alias CommsCore.Repo
  alias CommsWeb.Plugs.DistributedRateLimit
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL

  @origin "http://localhost:5173"
  @privacy_key "test-public-rate-limit-privacy-key-at-least-32-bytes"

  setup do
    SQL.query!(Repo, "DELETE FROM public_rate_limit_buckets", [])
    previous_proxies = Application.get_env(:comms_web, :trusted_proxy_cidrs)
    previous_privacy_key = Application.get_env(:comms_web, :public_rate_limit_privacy_key)

    on_exit(fn ->
      if previous_proxies,
        do: Application.put_env(:comms_web, :trusted_proxy_cidrs, previous_proxies),
        else: Application.delete_env(:comms_web, :trusted_proxy_cidrs)

      if previous_privacy_key,
        do:
          Application.put_env(
            :comms_web,
            :public_rate_limit_privacy_key,
            previous_privacy_key
          ),
        else: Application.delete_env(:comms_web, :public_rate_limit_privacy_key)
    end)

    :ok
  end

  test "returns JSON 429 and Retry-After after the distributed limit" do
    opts = opts(:instant_room_create, 1, 600)
    conn = client_conn({198, 51, 100, 21})

    refute conn |> DistributedRateLimit.call(opts) |> Map.fetch!(:halted)

    rejected = DistributedRateLimit.call(conn, opts)

    assert rejected.halted
    assert rejected.status == 429

    retry_after =
      rejected |> get_resp_header("retry-after") |> List.first() |> String.to_integer()

    assert retry_after in 1..600

    assert %{
             "error" => %{
               "code" => "rate_limited",
               "detail" => "Too many requests",
               "retry_after" => ^retry_after
             }
           } = Jason.decode!(rejected.resp_body)
  end

  test "stores only a fixed-size HMAC digest, never the raw client address" do
    conn = client_conn({203, 0, 113, 42})

    refute conn
           |> DistributedRateLimit.call(opts(:instant_room_join, 1, 600))
           |> Map.fetch!(:halted)

    assert [[key_digest, 32]] =
             SQL.query!(
               Repo,
               """
               SELECT key_digest, octet_length(key_digest)
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_join'
               """,
               []
             ).rows

    assert is_binary(key_digest)
    refute key_digest == "203.0.113.42"
    refute inspect(key_digest) =~ "203.0.113.42"
  end

  test "HMACs the normalized network with the configured privacy key" do
    Application.put_env(:comms_web, :public_rate_limit_privacy_key, @privacy_key)

    opts =
      DistributedRateLimit.init(
        scope: :instant_room_join,
        limit: 1,
        window: 600
      )

    refute client_conn({203, 0, 113, 42})
           |> DistributedRateLimit.call(opts)
           |> Map.fetch!(:halted)

    assert [[key_digest]] =
             SQL.query!(
               Repo,
               """
               SELECT key_digest
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_join'
               """,
               []
             ).rows

    expected =
      :crypto.mac(
        :hmac,
        :sha256,
        @privacy_key,
        IO.iodata_to_binary(["instant_room_join", 0, <<4, 32, 203, 0, 113, 42>>])
      )

    assert key_digest == expected
  end

  test "HMAC helper domain-separates trusted identity material by scope" do
    Application.put_env(:comms_web, :public_rate_limit_privacy_key, @privacy_key)
    material = ["session-1", 0, "conversation-1"]

    message_digest =
      DistributedRateLimit.key_digest(:instant_room_message, material, [])

    assert byte_size(message_digest) == 32

    assert message_digest ==
             :crypto.mac(
               :hmac,
               :sha256,
               @privacy_key,
               IO.iodata_to_binary(["instant_room_message", 0, material])
             )

    refute message_digest ==
             DistributedRateLimit.key_digest(:instant_room_join, material, [])

    assert_raise ArgumentError, fn ->
      apply(DistributedRateLimit, :key_digest, [:unsupported, material, []])
    end
  end

  test "authenticated subject source binds a bucket to tenant, user, and session" do
    opts =
      DistributedRateLimit.init(
        scope: :instant_room_conversion,
        limit: 2,
        window: 600,
        privacy_key: @privacy_key,
        key_source: :authenticated_subject
      )

    first_subject = %{
      tenant_id: "tenant-1",
      user_id: "user-1",
      session_id: "session-1"
    }

    second_subject = %{first_subject | session_id: "session-2"}

    refute {198, 51, 100, 31}
           |> client_conn()
           |> assign(:current_subject, first_subject)
           |> DistributedRateLimit.call(opts)
           |> halted?()

    refute {203, 0, 113, 31}
           |> client_conn()
           |> assign(:current_subject, first_subject)
           |> DistributedRateLimit.call(opts)
           |> halted?()

    refute {198, 51, 100, 31}
           |> client_conn()
           |> assign(:current_subject, second_subject)
           |> DistributedRateLimit.call(opts)
           |> halted?()

    assert [[first_digest, 2, 32], [second_digest, 1, 32]] =
             SQL.query!(
               Repo,
               """
               SELECT key_digest, request_count, octet_length(key_digest)
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_conversion'
               ORDER BY request_count DESC
               """,
               []
             ).rows

    refute first_digest == second_digest

    for identifier <- Map.values(first_subject) ++ Map.values(second_subject) do
      refute first_digest == identifier
      refute second_digest == identifier
      refute inspect([first_digest, second_digest]) =~ identifier
    end
  end

  test "authenticated subject source is conversion-only and fails closed without auth assigns" do
    assert_raise ArgumentError,
                 "authenticated subject rate limiting is only supported for instant-room conversion",
                 fn ->
                   DistributedRateLimit.init(
                     scope: :instant_room_join,
                     limit: 1,
                     window: 60,
                     key_source: :authenticated_subject
                   )
                 end

    opts =
      DistributedRateLimit.init(
        scope: :instant_room_conversion,
        limit: 1,
        window: 60,
        key_source: :authenticated_subject
      )

    assert_raise ArgumentError,
                 "authenticated subject rate limiting requires tenant, user, and session identifiers",
                 fn -> DistributedRateLimit.call(build_conn(), opts) end
  end

  test "router keeps network buckets and adds independent conversion session buckets" do
    account = Fixtures.account_fixture()

    restore_env(
      instant_rooms_enabled: true,
      instant_room_tenant_slug: account.tenant.slug
    )

    remote_ip = {198, 51, 100, 211}

    guests =
      for index <- 1..2 do
        remote_ip
        |> public_json_conn(random_idempotency_key())
        |> post(
          "/api/v1/instant-rooms",
          Jason.encode!(%{
            display_name: "Rate limit guest #{index}",
            device: %{name: "Browser #{index}", platform: "web"}
          })
        )
        |> json_response(201)
      end

    for guest <- guests do
      remote_ip
      |> public_json_conn()
      |> post(
        "/api/v1/instant-rooms/preview",
        Jason.encode!(%{token: guest["token"]})
      )
      |> json_response(200)
    end

    for {guest, index} <- Enum.with_index(guests, 1) do
      response =
        remote_ip
        |> client_conn()
        |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
        |> post("/api/v1/guest/account", %{
          email: "router-limit-#{index}@example.test",
          password: "correct-router-rate-limit-password-123",
          display_name: "",
          device: %{name: "Converted browser", platform: "web"}
        })
        |> json_response(422)

      assert response["error"]["code"] == "invalid_guest_account"
    end

    assert [[1, 2]] =
             SQL.query!(
               Repo,
               """
               SELECT count(DISTINCT key_digest), max(request_count)
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_create'
               """,
               []
             ).rows

    assert [[1, 2]] =
             SQL.query!(
               Repo,
               """
               SELECT count(DISTINCT key_digest), max(request_count)
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_join'
               """,
               []
             ).rows

    assert [[3, 2]] =
             SQL.query!(
               Repo,
               """
               SELECT count(DISTINCT key_digest), max(request_count)
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_conversion'
               """,
               []
             ).rows

    expected_conversion_network_digest =
      DistributedRateLimit.key_digest(
        :instant_room_conversion,
        <<4, 32, 198, 51, 100, 211>>
      )

    assert [[2]] =
             SQL.query!(
               Repo,
               """
               SELECT request_count
               FROM public_rate_limit_buckets
               WHERE scope = 'instant_room_conversion' AND key_digest = $1
               """,
               [expected_conversion_network_digest]
             ).rows
  end

  test "normalizes IPv4 per address and IPv6 by 64-bit client network" do
    ipv4_opts = opts(:instant_room_create, 1, 600)
    refute client_conn({198, 51, 100, 31}) |> DistributedRateLimit.call(ipv4_opts) |> halted?()
    assert client_conn({198, 51, 100, 31}) |> DistributedRateLimit.call(ipv4_opts) |> halted?()
    refute client_conn({198, 51, 100, 32}) |> DistributedRateLimit.call(ipv4_opts) |> halted?()

    ipv6_opts = opts(:instant_room_join, 1, 600)

    refute {0x2001, 0xDB8, 0x1234, 0x5678, 0, 0, 0, 1}
           |> client_conn()
           |> DistributedRateLimit.call(ipv6_opts)
           |> halted?()

    assert {0x2001, 0xDB8, 0x1234, 0x5678, 0xFFFF, 0, 0, 2}
           |> client_conn()
           |> DistributedRateLimit.call(ipv6_opts)
           |> halted?()

    refute {0x2001, 0xDB8, 0x1234, 0x5679, 0, 0, 0, 1}
           |> client_conn()
           |> DistributedRateLimit.call(ipv6_opts)
           |> halted?()

    mapped_opts = opts(:instant_room_message, 1, 600)

    refute client_conn({203, 0, 113, 7})
           |> DistributedRateLimit.call(mapped_opts)
           |> halted?()

    assert {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}
           |> client_conn()
           |> DistributedRateLimit.call(mapped_opts)
           |> halted?()
  end

  test "uses the trusted-proxy-derived address and ignores attacker-prepended hops" do
    Application.put_env(:comms_web, :trusted_proxy_cidrs, ["10.0.0.0/8"])
    opts = opts(:instant_room_join, 1, 600)

    first =
      {10, 0, 0, 5}
      |> client_conn()
      |> put_req_header("x-forwarded-for", "192.0.2.8, 203.0.113.9, 10.0.0.4")
      |> DistributedRateLimit.call(opts)

    second =
      {10, 0, 0, 5}
      |> client_conn()
      |> put_req_header("x-forwarded-for", "198.51.100.77, 203.0.113.9, 10.0.0.4")
      |> DistributedRateLimit.call(opts)

    refute first.halted
    assert second.halted
  end

  test "supports independent create, join, conversion, and message scopes" do
    conn = client_conn({198, 51, 100, 80})

    for scope <- PlatformRateLimits.scopes() do
      refute conn
             |> DistributedRateLimit.call(opts(scope, 1, 600))
             |> Map.fetch!(:halted)
    end

    for scope <- PlatformRateLimits.scopes() do
      assert conn
             |> DistributedRateLimit.call(opts(scope, 1, 600))
             |> Map.fetch!(:halted)
    end
  end

  test "instant-room creation enforces both minute burst and daily admission caps" do
    burst_client = client_conn({198, 51, 100, 91})
    minute = opts(:instant_room_create, 2, 60)
    daily = opts(:instant_room_create, 10, 86_400)

    for _request <- 1..2 do
      refute burst_client |> DistributedRateLimit.call(minute) |> halted?()
      refute burst_client |> DistributedRateLimit.call(daily) |> halted?()
    end

    burst_rejected = DistributedRateLimit.call(burst_client, minute)
    assert burst_rejected.halted
    assert get_resp_header(burst_rejected, "retry-after") != []

    daily_client = client_conn({198, 51, 100, 92})

    for _request <- 1..10 do
      refute daily_client |> DistributedRateLimit.call(daily) |> halted?()
    end

    daily_rejected = DistributedRateLimit.call(daily_client, daily)
    assert daily_rejected.halted
    assert get_resp_header(daily_rejected, "retry-after") != []
  end

  defp opts(scope, limit, window) do
    DistributedRateLimit.init(
      scope: scope,
      limit: limit,
      window: window,
      privacy_key: @privacy_key
    )
  end

  defp restore_env(settings) do
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
  end

  defp public_json_conn(remote_ip, idempotency_key \\ nil) do
    conn =
      remote_ip
      |> client_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", @origin)

    if idempotency_key,
      do: put_req_header(conn, "idempotency-key", idempotency_key),
      else: conn
  end

  defp random_idempotency_key,
    do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp client_conn(remote_ip), do: %{build_conn() | remote_ip: remote_ip}
  defp halted?(conn), do: conn.halted
end
