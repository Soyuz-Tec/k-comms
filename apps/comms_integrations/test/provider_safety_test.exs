defmodule CommsIntegrations.ProviderSafetyTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.{HttpPolicy, Notifications, Scanner}

  test "URL policy rejects credentials, IP literals, private destinations, and non-allowlisted hosts" do
    assert {:error, :outbound_https_required} =
             HttpPolicy.validate_https_destination(
               "http://hooks.example.test/events",
               ["hooks.example.test"],
               [443],
               resolve: false
             )

    assert {:error, :outbound_credentials_forbidden} =
             HttpPolicy.validate_https_destination(
               "https://user:password@hooks.example.test/events",
               ["hooks.example.test"],
               [443],
               resolve: false
             )

    assert {:error, :outbound_ip_literal_forbidden} =
             HttpPolicy.validate_https_destination(
               "https://127.0.0.1/events",
               ["127.0.0.1"],
               [443],
               resolve: false
             )

    assert {:error, :outbound_host_not_allowed} =
             HttpPolicy.validate_https_destination(
               "https://attacker.example/events",
               ["hooks.example.test"],
               [443],
               resolve: false
             )
  end

  test "missing production provider configuration is reported as unavailable" do
    previous_notification = Application.get_env(:comms_integrations, :notification_http)
    previous_adapter = Application.get_env(:comms_integrations, :notification_adapter)

    Application.put_env(:comms_integrations, :notification_adapter, Notifications.Http)
    Application.put_env(:comms_integrations, :notification_http, [])

    on_exit(fn ->
      restore(:notification_http, previous_notification)
      restore(:notification_adapter, previous_adapter)
    end)

    assert %{status: :unavailable, missing: missing} = Notifications.status()
    assert :endpoint in missing
    assert :token in missing
    assert {:error, :permanent, :notification_provider_unavailable} = Notifications.deliver(%{})
  end

  test "notification transport failures are retryable while configuration failures are terminal" do
    previous = Application.get_env(:comms_integrations, :notification_http)

    Application.put_env(:comms_integrations, :notification_http,
      endpoint: "https://notifications.example.test/send",
      token: "provider-token",
      provider_name: "provider",
      allowed_hosts: ["notifications.example.test"],
      allowed_ports: [443],
      resolver: fn _host -> [{93, 184, 216, 34}] end,
      transport: CommsIntegrations.ProviderSafetyTest.TransientTransport,
      timeout_ms: 1_000
    )

    on_exit(fn -> restore(:notification_http, previous) end)

    for reason <- [
          :outbound_dns_unavailable,
          :outbound_timeout,
          :outbound_transport_error,
          :outbound_tls_error
        ] do
      Process.put(:provider_transport_error, reason)

      assert {:error, ^reason} =
               Notifications.Http.deliver(%{
                 channel: :email,
                 destination: "user@example.test",
                 event_type: "message.created.v1",
                 payload: %{},
                 idempotency_key: "notification-delivery-0001"
               })
    end
  end

  test "webhooks retry only explicit transport failures and reject protocol failures permanently" do
    previous = Application.get_env(:comms_integrations, :webhook_http)

    Application.put_env(:comms_integrations, :webhook_http,
      allowed_hosts: ["hooks.example.test"],
      allowed_ports: [443],
      resolver: fn _host -> [{93, 184, 216, 34}] end,
      transport: CommsIntegrations.ProviderSafetyTest.TransientTransport,
      timeout_ms: 1_000
    )

    on_exit(fn -> restore(:webhook_http, previous) end)

    payload = %{
      "url" => "https://hooks.example.test/events",
      "secret" => "secret-value-with-enough-entropy",
      "body" => %{},
      "delivery_id" => "delivery-1",
      "event_type" => "message.created.v1",
      "idempotency_key" => "event-1-endpoint-1"
    }

    for reason <- [
          :outbound_dns_unavailable,
          :outbound_timeout,
          :outbound_transport_error,
          :outbound_tls_error
        ] do
      Process.put(:provider_transport_error, reason)
      assert {:error, ^reason} = CommsIntegrations.Webhooks.Http.deliver(payload)
    end

    for reason <- [
          :outbound_response_too_large,
          :outbound_response_headers_too_large,
          :outbound_invalid_response
        ] do
      Process.put(:provider_transport_error, reason)

      assert {:error, :permanent, ^reason} =
               CommsIntegrations.Webhooks.Http.deliver(payload)
    end
  end

  test "the pinned transport enforces one total deadline across a slow response stream" do
    destination = %{
      host: "hooks.example.test",
      port: 443,
      addresses: [{93, 184, 216, 34}],
      uri: URI.parse("https://hooks.example.test/events")
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :outbound_timeout} =
             CommsIntegrations.PinnedHttp.MintTransport.request(
               destination,
               :get,
               [],
               "",
               timeout_ms: 60,
               connect_timeout_ms: 20,
               mint_http: CommsIntegrations.ProviderSafetyTest.SlowDripMint
             )

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed >= 50
    assert elapsed < 250
  end

  test "the pinned transport bounds cumulative response headers across Mint chunks" do
    destination = %{
      host: "hooks.example.test",
      port: 443,
      addresses: [{93, 184, 216, 34}],
      uri: URI.parse("https://hooks.example.test/events")
    }

    scenarios = [
      {[[{"x-a", "1234"}], [{"x-b", "5678"}]],
       [max_response_header_bytes: 16, max_response_header_count: 10]},
      {[[{"x-a", "1"}], [{"x-b", "2"}]],
       [max_response_header_bytes: 100, max_response_header_count: 1]}
    ]

    for {chunks, limits} <- scenarios do
      Process.put(:response_header_chunks, chunks)

      assert {:error, :outbound_response_headers_too_large} =
               CommsIntegrations.PinnedHttp.MintTransport.request(
                 destination,
                 :get,
                 [],
                 "",
                 [
                   timeout_ms: 200,
                   connect_timeout_ms: 50,
                   mint_http: CommsIntegrations.ProviderSafetyTest.ChunkedHeadersMint
                 ] ++ limits
               )

      assert_received {:header_chunk, 0}
      assert_received {:header_chunk, 1}
    end
  end

  test "response boundary errors win when Mint closes with final response entries" do
    destination = %{
      host: "hooks.example.test",
      port: 443,
      addresses: [{93, 184, 216, 34}],
      uri: URI.parse("https://hooks.example.test/events")
    }

    Process.put(:response_header_chunks, [[{"x-oversized", "0123456789"}]])
    Process.put(:response_header_recv_error, true)

    assert {:error, :outbound_response_headers_too_large} =
             CommsIntegrations.PinnedHttp.MintTransport.request(
               destination,
               :get,
               [],
               "",
               timeout_ms: 200,
               connect_timeout_ms: 50,
               max_response_header_bytes: 16,
               max_response_header_count: 10,
               mint_http: CommsIntegrations.ProviderSafetyTest.ChunkedHeadersMint
             )

    assert_received {:header_chunk, 0}
  end

  test "DNS resolution and transport I/O share one total deadline" do
    test_pid = self()
    timeout = 120

    resolver = fn host, deadline ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)
      send(test_pid, {:resolver_deadline, host, deadline, remaining})
      Process.sleep(70)
      [{93, 184, 216, 34}]
    end

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :outbound_timeout} =
             CommsIntegrations.PinnedHttp.request(
               :get,
               "https://hooks.example.test/events",
               [],
               "",
               allowed_hosts: ["hooks.example.test"],
               allowed_ports: [443],
               resolver: resolver,
               timeout_ms: timeout,
               connect_timeout_ms: 30,
               mint_http: CommsIntegrations.ProviderSafetyTest.SlowDripMint
             )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:resolver_deadline, "hooks.example.test", deadline, resolver_remaining}
    assert deadline > started_at
    assert resolver_remaining in 1..timeout
    assert elapsed >= 100
    assert elapsed < 160
  end

  test "a timed out address falls through to a healthy pinned address within the deadline" do
    first_address = {93, 184, 216, 34}
    second_address = {93, 184, 216, 35}
    Process.put(:connect_outcomes, %{first_address => :timeout, second_address => :ok})

    destination = %{
      host: "hooks.example.test",
      port: 443,
      addresses: [first_address, second_address],
      uri: URI.parse("https://hooks.example.test/events")
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{status: 204}} =
             CommsIntegrations.PinnedHttp.MintTransport.request(
               destination,
               :get,
               [],
               "",
               timeout_ms: 240,
               connect_timeout_ms: 60,
               mint_http: CommsIntegrations.ProviderSafetyTest.AddressOutcomeMint
             )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:connect_attempt, ^first_address, 60}
    assert_received {:connect_attempt, ^second_address, second_timeout}
    assert second_timeout in 1..60
    assert elapsed >= 50
    assert elapsed < 200
  end

  test "a TLS failure is terminal and does not fall through to another address" do
    first_address = {93, 184, 216, 34}
    second_address = {93, 184, 216, 35}

    Process.put(:connect_outcomes, %{
      first_address => {:tls, {:tls_alert, {:unknown_ca, ~c"unknown ca"}}},
      second_address => :ok
    })

    destination = %{
      host: "hooks.example.test",
      port: 443,
      addresses: [first_address, second_address],
      uri: URI.parse("https://hooks.example.test/events")
    }

    assert {:error, :outbound_tls_error} =
             CommsIntegrations.PinnedHttp.MintTransport.request(
               destination,
               :get,
               [],
               "",
               timeout_ms: 240,
               connect_timeout_ms: 60,
               mint_http: CommsIntegrations.ProviderSafetyTest.AddressOutcomeMint
             )

    assert_received {:connect_attempt, ^first_address, 60}
    refute_received {:connect_attempt, ^second_address, _timeout}
  end

  test "resolved addresses share the same connection deadline budget" do
    first_address = {93, 184, 216, 34}
    second_address = {93, 184, 216, 35}

    destination = %{
      host: "hooks.example.test",
      port: 443,
      addresses: [first_address, second_address],
      uri: URI.parse("https://hooks.example.test/events")
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :outbound_transport_error} =
             CommsIntegrations.PinnedHttp.MintTransport.request(
               destination,
               :get,
               [],
               "",
               timeout_ms: 300,
               connect_timeout_ms: 300,
               mint_http: CommsIntegrations.ProviderSafetyTest.FailingConnectMint
             )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:connect_timeout, ^first_address, first_timeout}
    assert_received {:connect_timeout, ^second_address, second_timeout}
    assert first_timeout <= 150
    assert second_timeout < first_timeout
    assert elapsed < 250
  end

  test "provider status rejects endpoint and allowlist drift before delivery" do
    previous_notification = Application.get_env(:comms_integrations, :notification_http)

    previous_notification_adapter =
      Application.get_env(:comms_integrations, :notification_adapter)

    previous_scanner = Application.get_env(:comms_integrations, :scanner_http)
    previous_scanner_adapter = Application.get_env(:comms_integrations, :scanner_adapter)

    on_exit(fn ->
      restore(:notification_http, previous_notification)
      restore(:notification_adapter, previous_notification_adapter)
      restore(:scanner_http, previous_scanner)
      restore(:scanner_adapter, previous_scanner_adapter)
    end)

    drifted = [
      endpoint: "https://other.example.test/v1/provider",
      token: "provider-token",
      provider_name: "provider",
      allowed_hosts: ["approved.example.test"],
      allowed_ports: [443],
      timeout_ms: 1_000
    ]

    Application.put_env(:comms_integrations, :notification_adapter, Notifications.Http)
    Application.put_env(:comms_integrations, :notification_http, drifted)
    Application.put_env(:comms_integrations, :scanner_adapter, Scanner.Http)
    Application.put_env(:comms_integrations, :scanner_http, drifted)

    assert %{status: :unavailable, reason: :outbound_host_not_allowed} = Notifications.status()
    assert %{status: :unavailable, reason: :outbound_host_not_allowed} = Scanner.status()
  end

  test "development scanner adapter never invents a clean malware verdict" do
    previous = Application.get_env(:comms_integrations, :scanner_adapter)
    Application.put_env(:comms_integrations, :scanner_adapter, Scanner.Log)
    on_exit(fn -> restore(:scanner_adapter, previous) end)

    assert %{status: :degraded} = Scanner.status()

    assert {:error, :scanner_log_adapter_has_no_verdict} =
             Scanner.scan(%{tenant_id: "tenant", attachment_id: "attachment"})
  end

  test "the HTTP adapter connects to the already-approved address and never follows redirects" do
    previous = Application.get_env(:comms_integrations, :webhook_http)
    public_address = {93, 184, 216, 34}
    test_pid = self()

    resolver = fn "hooks.example.test" ->
      send(test_pid, :resolved_once)
      [public_address]
    end

    Application.put_env(:comms_integrations, :webhook_http,
      allowed_hosts: ["hooks.example.test"],
      allowed_ports: [443],
      resolver: resolver,
      transport: CommsIntegrations.ProviderSafetyTest.PinnedTransport,
      timeout_ms: 100
    )

    on_exit(fn -> restore(:webhook_http, previous) end)

    Process.put(:pinned_status, 204)

    assert {:ok, %{http_status: 204}} =
             CommsIntegrations.Webhooks.Http.deliver(%{
               "url" => "https://hooks.example.test/events",
               "secret" => "secret-value-with-enough-entropy",
               "body" => %{},
               "delivery_id" => "delivery-1",
               "event_type" => "message.created.v1",
               "idempotency_key" => "event-1-endpoint-1"
             })

    assert_received :resolved_once
    assert_received {:connected_address, ^public_address, "hooks.example.test", "/events"}

    Process.put(:pinned_status, 302)

    assert {:error, :permanent, {:webhook_status, 302}} =
             CommsIntegrations.Webhooks.Http.deliver(%{
               "url" => "https://hooks.example.test/redirect",
               "secret" => "secret-value-with-enough-entropy",
               "body" => %{}
             })

    assert_received {:connected_address, ^public_address, "hooks.example.test", "/redirect"}
    refute_received {:connected_address, _, _, _}
  end

  test "DNS answers containing any private or transition address fail closed" do
    assert {:error, :outbound_private_address_forbidden} =
             HttpPolicy.validate_https_destination(
               "https://hooks.example.test/events",
               ["hooks.example.test"],
               [443],
               resolver: fn _host -> [{93, 184, 216, 34}, {127, 0, 0, 1}] end
             )

    refute HttpPolicy.public_address?({0x2002, 0x0A00, 1, 0, 0, 0, 0, 1})
    refute HttpPolicy.public_address?({0x0064, 0xFF9B, 0, 0, 0, 0, 0x0A00, 1})
  end

  defp restore(key, nil), do: Application.delete_env(:comms_integrations, key)
  defp restore(key, value), do: Application.put_env(:comms_integrations, key, value)
end

defmodule CommsIntegrations.ProviderSafetyTest.PinnedTransport do
  def request(destination, _method, _headers, _body, _opts) do
    [address | _] = destination.addresses
    send(self(), {:connected_address, address, destination.host, destination.uri.path})

    {:ok,
     %{
       status: Process.get(:pinned_status, 204),
       headers: [],
       body: ""
     }}
  end
end

defmodule CommsIntegrations.ProviderSafetyTest.TransientTransport do
  def request(_destination, _method, _headers, _body, _opts),
    do: {:error, Process.get(:provider_transport_error, :outbound_transport_error)}
end

defmodule CommsIntegrations.ProviderSafetyTest.SlowDripMint do
  def connect(:https, _address, _port, _opts) do
    Process.sleep(10)
    {:ok, %{}}
  end

  def request(conn, _method, _target, _headers, _body) do
    Process.sleep(10)
    {:ok, conn, :request}
  end

  def recv(conn, 0, timeout) do
    Process.sleep(min(timeout, 15))
    {:ok, conn, [{:data, :request, "x"}]}
  end

  def close(_conn), do: :ok
end

defmodule CommsIntegrations.ProviderSafetyTest.FailingConnectMint do
  def connect(:https, address, _port, opts) do
    timeout = opts |> Keyword.fetch!(:transport_opts) |> Keyword.fetch!(:timeout)
    send(self(), {:connect_timeout, address, timeout})
    Process.sleep(50)
    {:error, :closed}
  end
end

defmodule CommsIntegrations.ProviderSafetyTest.AddressOutcomeMint do
  def connect(:https, address, _port, opts) do
    timeout = opts |> Keyword.fetch!(:transport_opts) |> Keyword.fetch!(:timeout)
    send(self(), {:connect_attempt, address, timeout})

    case Process.get(:connect_outcomes, %{}) |> Map.get(address, :ok) do
      :ok ->
        {:ok, %{address: address}}

      :timeout ->
        Process.sleep(timeout)
        {:error, %Mint.TransportError{reason: :timeout}}

      {:tls, reason} ->
        {:error, %Mint.TransportError{reason: reason}}
    end
  end

  def request(conn, _method, _target, _headers, _body), do: {:ok, conn, :request}

  def recv(conn, 0, _timeout) do
    {:ok, conn, [{:status, :request, 204}, {:headers, :request, []}, {:done, :request}]}
  end

  def close(_conn), do: :ok
end

defmodule CommsIntegrations.ProviderSafetyTest.ChunkedHeadersMint do
  def connect(:https, _address, _port, _opts), do: {:ok, %{}}

  def request(conn, _method, _target, _headers, _body) do
    Process.put(:response_header_chunk_index, 0)
    {:ok, conn, :request}
  end

  def recv(conn, 0, _timeout) do
    chunks = Process.get(:response_header_chunks, [])
    index = Process.get(:response_header_chunk_index, 0)
    headers = Enum.fetch!(chunks, index)
    Process.put(:response_header_chunk_index, index + 1)
    send(self(), {:header_chunk, index})

    entries =
      if index == 0,
        do: [{:status, :request, 200}, {:headers, :request, headers}],
        else: [{:headers, :request, headers}]

    entries = if index == length(chunks) - 1, do: entries ++ [{:done, :request}], else: entries

    if Process.get(:response_header_recv_error, false),
      do: {:error, conn, :closed, entries},
      else: {:ok, conn, entries}
  end

  def close(_conn), do: :ok
end
