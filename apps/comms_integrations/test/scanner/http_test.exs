defmodule CommsIntegrations.Scanner.HttpTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.ProviderSafetyTestSupport, as: Support
  alias CommsIntegrations.Scanner

  @moduletag :integration
  @moduletag :external_delivery

  test "status rejects endpoint and allowlist drift before scanner delivery" do
    previous_scanner = Application.get_env(:comms_integrations, :scanner_http)
    previous_adapter = Application.get_env(:comms_integrations, :scanner_adapter)

    on_exit(fn ->
      Support.restore(:scanner_http, previous_scanner)
      Support.restore(:scanner_adapter, previous_adapter)
    end)

    Application.put_env(:comms_integrations, :scanner_adapter, Scanner.Http)

    Application.put_env(:comms_integrations, :scanner_http,
      endpoint: "https://other.example.test/v1/provider",
      token: "provider-token",
      provider_name: "provider",
      allowed_hosts: ["approved.example.test"],
      allowed_ports: [443],
      timeout_ms: 1_000
    )

    assert %{status: :unavailable, reason: :outbound_host_not_allowed} = Scanner.status()
  end

  test "development scanner adapter never invents a clean malware verdict" do
    previous = Application.get_env(:comms_integrations, :scanner_adapter)
    Application.put_env(:comms_integrations, :scanner_adapter, Scanner.Log)
    on_exit(fn -> Support.restore(:scanner_adapter, previous) end)

    assert %{status: :degraded} = Scanner.status()

    assert {:error, :scanner_log_adapter_has_no_verdict} =
             Scanner.scan(%{tenant_id: "tenant", attachment_id: "attachment"})
  end
end
