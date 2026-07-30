defmodule CommsIntegrations.Notifications.HttpTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.Notifications
  alias CommsIntegrations.ProviderSafetyTestSupport, as: Support
  alias CommsIntegrations.ProviderSafetyTestSupport.TransientTransport

  @moduletag :integration
  @moduletag :external_delivery

  test "missing production provider configuration is reported as unavailable" do
    previous_notification = Application.get_env(:comms_integrations, :notification_http)
    previous_adapter = Application.get_env(:comms_integrations, :notification_adapter)

    Application.put_env(:comms_integrations, :notification_adapter, Notifications.Http)
    Application.put_env(:comms_integrations, :notification_http, [])

    on_exit(fn ->
      Support.restore(:notification_http, previous_notification)
      Support.restore(:notification_adapter, previous_adapter)
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
      transport: TransientTransport,
      timeout_ms: 1_000
    )

    on_exit(fn -> Support.restore(:notification_http, previous) end)

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

  test "status rejects endpoint and allowlist drift before notification delivery" do
    previous_notification = Application.get_env(:comms_integrations, :notification_http)
    previous_adapter = Application.get_env(:comms_integrations, :notification_adapter)

    on_exit(fn ->
      Support.restore(:notification_http, previous_notification)
      Support.restore(:notification_adapter, previous_adapter)
    end)

    Application.put_env(:comms_integrations, :notification_adapter, Notifications.Http)

    Application.put_env(:comms_integrations, :notification_http,
      endpoint: "https://other.example.test/v1/provider",
      token: "provider-token",
      provider_name: "provider",
      allowed_hosts: ["approved.example.test"],
      allowed_ports: [443],
      timeout_ms: 1_000
    )

    assert %{status: :unavailable, reason: :outbound_host_not_allowed} = Notifications.status()
  end
end
