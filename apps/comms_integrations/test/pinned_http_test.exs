defmodule CommsIntegrations.PinnedHttpTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.PinnedHttp
  alias CommsIntegrations.ProviderSafetyTestSupport, as: Support
  alias CommsIntegrations.ProviderSafetyTestSupport.AddressOutcomeMint
  alias CommsIntegrations.ProviderSafetyTestSupport.ChunkedHeadersMint
  alias CommsIntegrations.ProviderSafetyTestSupport.FailingConnectMint
  alias CommsIntegrations.ProviderSafetyTestSupport.SlowDripMint

  @moduletag :unit
  @moduletag :external_delivery

  test "the pinned transport enforces one total deadline across a slow response stream" do
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :outbound_timeout} =
             PinnedHttp.MintTransport.request(
               Support.destination(),
               :get,
               [],
               "",
               timeout_ms: 60,
               connect_timeout_ms: 20,
               mint_http: SlowDripMint
             )

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed >= 50
    assert elapsed < 250
  end

  test "the pinned transport bounds cumulative response headers across Mint chunks" do
    scenarios = [
      {[[{"x-a", "1234"}], [{"x-b", "5678"}]],
       [max_response_header_bytes: 16, max_response_header_count: 10]},
      {[[{"x-a", "1"}], [{"x-b", "2"}]],
       [max_response_header_bytes: 100, max_response_header_count: 1]}
    ]

    for {chunks, limits} <- scenarios do
      Process.put(:response_header_chunks, chunks)

      assert {:error, :outbound_response_headers_too_large} =
               PinnedHttp.MintTransport.request(
                 Support.destination(),
                 :get,
                 [],
                 "",
                 [
                   timeout_ms: 200,
                   connect_timeout_ms: 50,
                   mint_http: ChunkedHeadersMint
                 ] ++ limits
               )

      assert_received {:header_chunk, 0}
      assert_received {:header_chunk, 1}
    end
  end

  test "response boundary errors win when Mint closes with final response entries" do
    Process.put(:response_header_chunks, [[{"x-oversized", "0123456789"}]])
    Process.put(:response_header_recv_error, true)

    assert {:error, :outbound_response_headers_too_large} =
             PinnedHttp.MintTransport.request(
               Support.destination(),
               :get,
               [],
               "",
               timeout_ms: 200,
               connect_timeout_ms: 50,
               max_response_header_bytes: 16,
               max_response_header_count: 10,
               mint_http: ChunkedHeadersMint
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
             PinnedHttp.request(
               :get,
               "https://hooks.example.test/events",
               [],
               "",
               allowed_hosts: ["hooks.example.test"],
               allowed_ports: [443],
               resolver: resolver,
               timeout_ms: timeout,
               connect_timeout_ms: 30,
               mint_http: SlowDripMint
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

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{status: 204}} =
             PinnedHttp.MintTransport.request(
               Support.destination([first_address, second_address]),
               :get,
               [],
               "",
               timeout_ms: 240,
               connect_timeout_ms: 60,
               mint_http: AddressOutcomeMint
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

    assert {:error, :outbound_tls_error} =
             PinnedHttp.MintTransport.request(
               Support.destination([first_address, second_address]),
               :get,
               [],
               "",
               timeout_ms: 240,
               connect_timeout_ms: 60,
               mint_http: AddressOutcomeMint
             )

    assert_received {:connect_attempt, ^first_address, 60}
    refute_received {:connect_attempt, ^second_address, _timeout}
  end

  test "resolved addresses share the same connection deadline budget" do
    first_address = {93, 184, 216, 34}
    second_address = {93, 184, 216, 35}
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :outbound_transport_error} =
             PinnedHttp.MintTransport.request(
               Support.destination([first_address, second_address]),
               :get,
               [],
               "",
               timeout_ms: 300,
               connect_timeout_ms: 300,
               mint_http: FailingConnectMint
             )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:connect_timeout, ^first_address, first_timeout}
    assert_received {:connect_timeout, ^second_address, second_timeout}
    assert first_timeout <= 150
    assert second_timeout < first_timeout
    assert elapsed < 250
  end
end
