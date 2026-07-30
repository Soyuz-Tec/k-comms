defmodule CommsIntegrations.LocalReleaseGuard.TrustedEdgeTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.LocalReleaseGuard
  import CommsIntegrations.LocalReleaseGuardTestOptions

  @moduletag :unit
  @moduletag :release

  test "accepts one explicitly confirmed Cloudflare trusted-edge topology" do
    assert :ok = LocalReleaseGuard.validate!(trusted_edge_options())
  end

  test "trusted-edge mode requires the local-release gate and exact confirmation" do
    assert_raise ArgumentError, ~r/requires K_COMMS_LOCAL_RELEASE=true/, fn ->
      LocalReleaseGuard.validate!(trusted_edge_options(enabled?: false))
    end

    for confirmation <- [nil, "", "cloudflare-tunnel-v2", " cloudflare-tunnel-v1"] do
      assert_raise ArgumentError, ~r/K_COMMS_TRUSTED_EDGE_CONFIRMATION must exactly equal/, fn ->
        LocalReleaseGuard.validate!(trusted_edge_options(trusted_edge_confirmation: confirmation))
      end
    end

    assert_raise ArgumentError, ~r/K_COMMS_TRUSTED_EDGE_CONFIRMATION is valid only/, fn ->
      LocalReleaseGuard.validate!(options(trusted_edge_confirmation: "cloudflare-tunnel-v1"))
    end

    assert :ok = LocalReleaseGuard.validate!(options(trusted_edge_confirmation: ""))

    assert_raise ArgumentError, ~r/K_COMMS_RELEASE_EXPOSURE_MODE must be unset or exactly/, fn ->
      LocalReleaseGuard.validate!(options(exposure_mode: "cloudflare"))
    end
  end

  test "trusted-edge mode requires exact public origins and the internal LiveKit API" do
    for {field, value, error} <- [
          {:public_app_url, "http://comms.avayaworks.com", ~r/PUBLIC_APP_URL must be an exact/},
          {:public_app_url, "https://comms.avayaworks.com:8443",
           ~r/PUBLIC_APP_URL must be an exact/},
          {:public_app_url, "https://comms.avayaworks.com:443",
           ~r/PUBLIC_APP_URL must be an exact/},
          {:public_app_url, "https://comms.avayaworks.com/", ~r/PUBLIC_APP_URL must be an exact/},
          {:public_app_url, "https://comms.avayaworks.com/app",
           ~r/PUBLIC_APP_URL must be an exact/},
          {:public_app_url, "https://COMMS.avayaworks.com", ~r/PUBLIC_APP_URL must be an exact/},
          {:public_app_url, "https://127.0.0.1", ~r/PUBLIC_APP_URL must be an exact/},
          {:phx_host, "media.avayaworks.com", ~r/PHX_HOST must exactly match/},
          {:phx_host, "COMMS.avayaworks.com", ~r/PHX_HOST must be one canonical/},
          {:livekit_server_url, "ws://media.avayaworks.com",
           ~r/LIVEKIT_SERVER_URL must be an exact/},
          {:livekit_server_url, "wss://media.avayaworks.com/path",
           ~r/LIVEKIT_SERVER_URL must be an exact/},
          {:livekit_server_url, "wss://media.avayaworks.com:443",
           ~r/LIVEKIT_SERVER_URL must be an exact/},
          {:livekit_api_url, "https://livekit:7880", ~r/LIVEKIT_API_URL must be an exact/},
          {:livekit_api_url, "http://livekit:7881", ~r/LIVEKIT_API_URL must be an exact/},
          {:s3_public_endpoint, "http://objects.avayaworks.com",
           ~r/S3_PUBLIC_ENDPOINT must be an exact/},
          {:s3_public_endpoint, "https://objects.avayaworks.com:9000",
           ~r/S3_PUBLIC_ENDPOINT must be an exact/},
          {:s3_public_endpoint, "https://objects.avayaworks.com:443",
           ~r/S3_PUBLIC_ENDPOINT must be an exact/}
        ] do
      assert_raise ArgumentError, error, fn ->
        LocalReleaseGuard.validate!(trusted_edge_options([{field, value}]))
      end
    end
  end

  test "trusted-edge mode keeps CORS, CSP, HSTS, and proxy trust exact" do
    for cors_origins <- [
          [],
          ["https://other.avayaworks.com"],
          ["https://comms.avayaworks.com:443"],
          ["https://comms.avayaworks.com", "https://other.avayaworks.com"]
        ] do
      assert_raise ArgumentError, ~r/CORS_ORIGINS must contain exactly/, fn ->
        LocalReleaseGuard.validate!(trusted_edge_options(cors_origins: cors_origins))
      end
    end

    for csp_connect_sources <- [
          [],
          ["'self'", "https://objects.avayaworks.com", "wss://media.avayaworks.com"],
          [
            "'self'",
            "wss://media.avayaworks.com",
            "https://objects.avayaworks.com",
            "https://extra.avayaworks.com"
          ]
        ] do
      assert_raise ArgumentError, ~r/CSP_CONNECT_SOURCES must contain exactly/, fn ->
        LocalReleaseGuard.validate!(
          trusted_edge_options(csp_connect_sources: csp_connect_sources)
        )
      end
    end

    assert_raise ArgumentError, ~r/HSTS_ENABLED must be true/, fn ->
      LocalReleaseGuard.validate!(trusted_edge_options(hsts?: false))
    end

    for trusted_proxy_cidrs <- [
          [],
          ["10.0.0.0/8"],
          ["192.168.0.0/16"],
          ["10.89.0.0/24"],
          ["10.89.0.12"],
          ["203.0.113.10/32"],
          ["127.0.0.1/32"],
          ["fd12:3456::1/64"],
          ["fd12:3456::1/128"],
          ["10.89.0.12/32", "10.89.0.13/32"],
          ["10.89.0.12/032"],
          ["10.89.0.012/32"],
          ["10.89.0.12/32 "],
          ["not-a-network"]
        ] do
      assert_raise ArgumentError, ~r/TRUSTED_PROXY_CIDRS must contain/, fn ->
        LocalReleaseGuard.validate!(
          trusted_edge_options(trusted_proxy_cidrs: trusted_proxy_cidrs)
        )
      end
    end
  end

  test "trusted-edge mode cannot reuse the disposable qualification origin exception" do
    assert_raise ArgumentError, ~r/K_COMMS_QUALIFICATION_APP_ORIGIN is not valid/, fn ->
      LocalReleaseGuard.validate!(
        trusted_edge_options(
          role: "edge",
          instant_room_tenant_slug: "k-comms-qualification-0123456789abcdef0123456789abcdef",
          qualification_app_origin: "http://127.0.0.1:45231",
          qualification_app_confirmation: "local-release-qualification-app-v1"
        )
      )
    end
  end
end
