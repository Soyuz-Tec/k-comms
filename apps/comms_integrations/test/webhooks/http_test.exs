defmodule CommsIntegrations.Webhooks.HttpTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.ProviderSafetyTestSupport, as: Support
  alias CommsIntegrations.ProviderSafetyTestSupport.PinnedTransport
  alias CommsIntegrations.ProviderSafetyTestSupport.TransientTransport
  alias CommsIntegrations.Webhooks

  @moduletag :integration
  @moduletag :external_delivery

  test "webhooks retry only explicit transport failures and reject protocol failures permanently" do
    previous = Application.get_env(:comms_integrations, :webhook_http)

    Application.put_env(:comms_integrations, :webhook_http,
      allowed_hosts: ["hooks.example.test"],
      allowed_ports: [443],
      resolver: fn _host -> [{93, 184, 216, 34}] end,
      transport: TransientTransport,
      timeout_ms: 1_000
    )

    on_exit(fn -> Support.restore(:webhook_http, previous) end)
    payload = Support.webhook_payload()

    for reason <- [
          :outbound_dns_unavailable,
          :outbound_timeout,
          :outbound_transport_error,
          :outbound_tls_error
        ] do
      Process.put(:provider_transport_error, reason)
      assert {:error, ^reason} = Webhooks.Http.deliver(payload)
    end

    for reason <- [
          :outbound_response_too_large,
          :outbound_response_headers_too_large,
          :outbound_invalid_response
        ] do
      Process.put(:provider_transport_error, reason)
      assert {:error, :permanent, ^reason} = Webhooks.Http.deliver(payload)
    end
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
      transport: PinnedTransport,
      timeout_ms: 100
    )

    on_exit(fn -> Support.restore(:webhook_http, previous) end)
    Process.put(:pinned_status, 204)

    assert {:ok, %{http_status: 204}} =
             Webhooks.Http.deliver(%{
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
             Webhooks.Http.deliver(%{
               "url" => "https://hooks.example.test/redirect",
               "secret" => "secret-value-with-enough-entropy",
               "body" => %{}
             })

    assert_received {:connected_address, ^public_address, "hooks.example.test", "/redirect"}
    refute_received {:connected_address, _, _, _}
  end
end
