defmodule CommsIntegrations.HttpPolicyTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.HttpPolicy

  @moduletag :unit
  @moduletag :external_delivery

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
end
