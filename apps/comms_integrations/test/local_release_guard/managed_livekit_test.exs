defmodule CommsIntegrations.LocalReleaseGuard.ManagedLiveKitTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.LocalReleaseGuard
  import CommsIntegrations.LocalReleaseGuardTestOptions

  @moduletag :unit
  @moduletag :release

  test "accepts explicitly confirmed managed LiveKit in trusted-edge mode" do
    assert :ok =
             LocalReleaseGuard.validate!(
               trusted_edge_options(
                 livekit_topology: "managed_cloud",
                 managed_livekit_confirmation: "livekit-cloud-v1",
                 livekit_server_url: "wss://project-k-comms.livekit.cloud",
                 livekit_api_url: "https://project-k-comms.livekit.cloud",
                 csp_connect_sources: [
                   "'self'",
                   "wss://project-k-comms.livekit.cloud",
                   "https://objects.avayaworks.com"
                 ]
               )
             )
  end

  test "accepts explicitly confirmed managed LiveKit from a private-LAN release" do
    host = "192.168.50.25"

    assert :ok =
             LocalReleaseGuard.validate!(
               lan_options(
                 livekit_topology: "managed_cloud",
                 managed_livekit_confirmation: "livekit-cloud-v1",
                 livekit_server_url: "wss://project-k-comms.livekit.cloud",
                 livekit_api_url: "https://project-k-comms.livekit.cloud",
                 csp_connect_sources: [
                   "'self'",
                   "http://#{host}:4188",
                   "ws://#{host}:4188",
                   "wss://project-k-comms.livekit.cloud",
                   "http://#{host}:5900"
                 ]
               )
             )
  end

  test "managed LiveKit requires exact confirmation and matching public origins" do
    for confirmation <- [nil, "", "livekit-cloud-v2", " livekit-cloud-v1"] do
      assert_raise ArgumentError,
                   ~r/K_COMMS_MANAGED_LIVEKIT_CONFIRMATION must exactly equal/,
                   fn ->
                     LocalReleaseGuard.validate!(
                       trusted_edge_options(
                         livekit_topology: "managed_cloud",
                         managed_livekit_confirmation: confirmation
                       )
                     )
                   end
    end

    assert_raise ArgumentError, ~r/same public host/, fn ->
      LocalReleaseGuard.validate!(
        trusted_edge_options(
          livekit_topology: "managed_cloud",
          managed_livekit_confirmation: "livekit-cloud-v1",
          livekit_server_url: "wss://project-k-comms.livekit.cloud",
          livekit_api_url: "https://other-project.livekit.cloud"
        )
      )
    end

    assert_raise ArgumentError, ~r/valid only when/, fn ->
      LocalReleaseGuard.validate!(
        trusted_edge_options(managed_livekit_confirmation: "livekit-cloud-v1")
      )
    end
  end
end
