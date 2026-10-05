defmodule CommsIntegrations.PhoneProvisioningProtocolTest do
  use ExUnit.Case, async: false
  alias CommsIntegrations.Telephony.ProvisioningLiveKit
  alias CommsCore.Telephony.ProvisioningRequest

  test "official modern dispatch fields isolate trunk, called DID and one private room per caller" do
    body = ProvisioningLiveKit.create_body(request())

    assert %{
             dispatch_rule: %{
               trunk_ids: ["ST_in"],
               numbers: ["+14155550123"],
               hide_phone_number: false,
               rule: %{
                 dispatch_rule_individual: %{
                   room_prefix: "kc_tel_inbound_",
                   pin: "",
                   no_randomness: false
                 }
               }
             }
           } = body

    refute Map.has_key?(body.dispatch_rule, :inbound_numbers)
    refute Map.has_key?(body.dispatch_rule, :room_config)
    refute Jason.encode!(body) =~ "password"
  end

  test "operator bindings cannot share a trunk or DID across tenants or accept secret fields" do
    tenant = "11111111-1111-4111-8111-111111111111"
    other = "22222222-2222-4222-8222-222222222222"

    binding = %{
      inbound_trunk_ids: ["ST_in"],
      outbound_trunk_ids: ["ST_out"],
      phone_numbers: ["+14155550123"]
    }

    assert ProvisioningLiveKit.valid_bindings?(%{tenant => binding})
    refute ProvisioningLiveKit.valid_bindings?(%{tenant => binding, other => binding})

    refute ProvisioningLiveKit.valid_bindings?(%{
             tenant => Map.put(binding, :auth_password, "secret")
           })

    refute ProvisioningLiveKit.valid_bindings?(%{tenant => %{binding | phone_numbers: []}})
  end

  test "disabled provider setup performs no HTTP even with synthetically supplied IDs" do
    previous = Application.get_env(:comms_core, :telephony_provisioning_enabled)
    Application.put_env(:comms_core, :telephony_provisioning_enabled, false)

    try do
      assert {:error, :provider_binding_forbidden} =
               ProvisioningLiveKit.inspect(request(), fn _, _, _, _, _ ->
                 flunk("Disabled management performed HTTP")
               end)
    after
      if previous == nil,
        do: Application.delete_env(:comms_core, :telephony_provisioning_enabled),
        else: Application.put_env(:comms_core, :telephony_provisioning_enabled, previous)
    end
  end

  defp request,
    do: %ProvisioningRequest{
      command_id: "33333333-3333-4333-8333-333333333333",
      tenant_id: "11111111-1111-4111-8111-111111111111",
      lease_token: "synthetic-opaque-lease",
      lease_expires_at: DateTime.add(DateTime.utc_now(), 15),
      version: 1,
      mode: :inspect,
      phone_number: "+14155550123",
      inbound_trunk_id: "ST_in",
      outbound_trunk_id: "ST_out"
    }
end
