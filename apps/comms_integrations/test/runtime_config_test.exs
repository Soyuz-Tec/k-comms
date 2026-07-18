defmodule CommsIntegrations.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.RuntimeConfig

  test "rejects unknown modes instead of silently selecting deny-all" do
    assert_raise ArgumentError, ~r/NOTIFICATION_PROVIDER_MODE must be one of/, fn ->
      RuntimeConfig.validate!(options(notification_mode: "htp"))
    end
  end

  test "requires the explicit development gate for every synthetic adapter" do
    assert_raise ArgumentError, ~r/ALLOW_DEVELOPMENT_ADAPTERS=true/, fn ->
      RuntimeConfig.validate!(options(notification_mode: "log"))
    end

    assert_raise ArgumentError, ~r/ALLOW_DEVELOPMENT_ADAPTERS=true/, fn ->
      RuntimeConfig.validate!(options(scanner_mode: "allow_all"))
    end

    assert_raise ArgumentError, ~r/ALLOW_DEVELOPMENT_ADAPTERS=true/, fn ->
      RuntimeConfig.validate!(options(webhook_mode: "log"))
    end
  end

  test "accepts explicit local qualification adapters and identifies degraded push delivery" do
    result =
      RuntimeConfig.validate!(
        options(
          notification_mode: "log",
          scanner_mode: "allow_all",
          webhook_mode: "log",
          development_adapters?: true
        )
      )

    assert result.notification_adapter == CommsIntegrations.Notifications.Log
    assert result.notification_delivery_status == :degraded
    assert result.scanner_adapter == CommsIntegrations.Scanner.AllowAll
    assert result.webhook_adapter == CommsIntegrations.Webhooks.Log
  end

  test "accepts coherent HTTPS provider configuration" do
    result =
      RuntimeConfig.validate!(
        options(
          notification_mode: "http",
          scanner_mode: "http",
          webhook_mode: "http"
        )
      )

    assert result.notification_adapter == CommsIntegrations.Notifications.Http
    assert result.notification_delivery_status == :available
    assert result.scanner_adapter == CommsIntegrations.Scanner.Http
    assert result.webhook_adapter == CommsIntegrations.Webhooks.Http
  end

  test "rejects missing provider credentials without including their values" do
    error =
      assert_raise ArgumentError, fn ->
        RuntimeConfig.validate!(
          options(
            notification_mode: "http",
            notification_http:
              Keyword.put(notification_http(), :token, "sensitive-provider-token")
              |> Keyword.put(:provider_name, nil)
          )
        )
      end

    assert Exception.message(error) =~ "NOTIFICATION_PROVIDER_NAME is required"
    refute Exception.message(error) =~ "sensitive-provider-token"
  end

  test "rejects non-HTTPS and non-allowlisted provider endpoints" do
    assert_raise ArgumentError, ~r/NOTIFICATION_PROVIDER_ENDPOINT.*outbound_https_required/, fn ->
      RuntimeConfig.validate!(
        options(
          notification_mode: "http",
          notification_http:
            Keyword.put(notification_http(), :endpoint, "http://notifications.example.test/v1")
        )
      )
    end

    assert_raise ArgumentError, ~r/ATTACHMENT_SCANNER_ENDPOINT.*outbound_host_not_allowed/, fn ->
      RuntimeConfig.validate!(
        options(
          scanner_mode: "http",
          scanner_http:
            Keyword.put(scanner_http(), :endpoint, "https://other.example.test/v1/scan")
        )
      )
    end
  end

  test "requires explicit webhook hosts and bounded provider timeouts" do
    assert_raise ArgumentError, ~r/WEBHOOK_ALLOWED_HOSTS/, fn ->
      RuntimeConfig.validate!(
        options(webhook_mode: "http", webhook_http: [allowed_hosts: [], timeout_ms: 10_000])
      )
    end

    assert_raise ArgumentError, ~r/NOTIFICATION_PROVIDER_TIMEOUT_MS/, fn ->
      RuntimeConfig.validate!(
        options(
          notification_mode: "http",
          notification_http: Keyword.put(notification_http(), :timeout_ms, 0)
        )
      )
    end
  end

  test "one-shot release commands do not need unrelated provider credentials" do
    result =
      RuntimeConfig.validate!(
        options(
          notification_mode: "http",
          scanner_mode: "http",
          webhook_mode: "http",
          provider_preflight?: false,
          notification_http: [],
          scanner_http: [],
          webhook_http: []
        )
      )

    assert result.notification_adapter == CommsIntegrations.Notifications.Http
    assert result.scanner_adapter == CommsIntegrations.Scanner.Http
    assert result.webhook_adapter == CommsIntegrations.Webhooks.Http
  end

  defp options(overrides) do
    Keyword.merge(
      [
        notification_mode: "disabled",
        scanner_mode: "disabled",
        webhook_mode: "disabled",
        development_adapters?: false,
        notification_http: notification_http(),
        scanner_http: scanner_http(),
        webhook_http: webhook_http()
      ],
      overrides
    )
  end

  defp notification_http do
    [
      endpoint: "https://notifications.example.test/v1/deliver",
      token: "notification-test-token",
      provider_name: "notification-test-provider",
      allowed_hosts: ["notifications.example.test"],
      allowed_ports: [443],
      timeout_ms: 10_000
    ]
  end

  defp scanner_http do
    [
      endpoint: "https://scanner.example.test/v1/scan",
      token: "scanner-test-token",
      provider_name: "scanner-test-provider",
      allowed_hosts: ["scanner.example.test"],
      allowed_ports: [443],
      timeout_ms: 30_000
    ]
  end

  defp webhook_http do
    [allowed_hosts: ["hooks.example.test"], allowed_ports: [443], timeout_ms: 10_000]
  end
end
