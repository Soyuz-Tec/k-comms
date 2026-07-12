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
    assert {:error, :notification_provider_unavailable} = Notifications.deliver(%{})
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

    resolver = fn "hooks.example.test" ->
      send(self(), :resolved_once)
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
