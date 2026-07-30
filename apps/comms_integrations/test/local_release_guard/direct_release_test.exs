defmodule CommsIntegrations.LocalReleaseGuard.DirectReleaseTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.LocalReleaseGuard
  import CommsIntegrations.LocalReleaseGuardTestOptions

  @moduletag :unit
  @moduletag :release

  test "accepts only the explicit loopback Compose qualification topology" do
    assert :ok = LocalReleaseGuard.validate!(options())
  end

  test "accepts one explicitly selected RFC1918 host across every public origin" do
    for host <- ["10.20.30.40", "172.16.0.10", "172.31.255.254", "192.168.50.25"] do
      assert :ok =
               LocalReleaseGuard.validate!(
                 options(
                   local_release_host: host,
                   phx_host: host,
                   public_app_url: "http://#{host}:4188",
                   livekit_server_url: "ws://#{host}:7980",
                   s3_public_endpoint: "http://#{host}:5900",
                   cors_origins: ["http://#{host}:4188"],
                   csp_connect_sources: [
                     "'self'",
                     "http://#{host}:4188",
                     "ws://#{host}:4188",
                     "ws://#{host}:7980",
                     "http://#{host}:5900"
                   ]
                 )
               )
    end
  end

  test "an explicit release host requires the same host everywhere" do
    assert_raise ArgumentError, ~r/PHX_HOST must exactly match/, fn ->
      LocalReleaseGuard.validate!(lan_options(phx_host: "127.0.0.1"))
    end

    for {field, value, error} <- [
          {:public_app_url, "http://127.0.0.1:4188", ~r/PUBLIC_APP_URL must be an exact/},
          {:livekit_server_url, "ws://127.0.0.1:7980", ~r/LIVEKIT_SERVER_URL must be an exact/},
          {:s3_public_endpoint, "http://127.0.0.1:5900", ~r/S3_PUBLIC_ENDPOINT must be an exact/},
          {:cors_origins, ["http://192.168.50.25:4188", "http://127.0.0.1:4188"],
           ~r/CORS_ORIGINS must be an exact/},
          {:csp_connect_sources, ["'self'", "ws://127.0.0.1:7980"],
           ~r/CSP_CONNECT_SOURCES must be an exact/}
        ] do
      assert_raise ArgumentError, error, fn ->
        LocalReleaseGuard.validate!(lan_options([{field, value}]))
      end
    end
  end

  test "rejects public, reserved, non-canonical, and malformed explicit release hosts" do
    for invalid <- [
          "",
          " 192.168.50.25 ",
          "192.168.050.025",
          "8.8.8.8",
          "192.0.2.10",
          "100.64.0.10",
          "169.254.0.10",
          "0.0.0.0",
          "172.15.0.10",
          "172.32.0.10",
          "comms.internal",
          "*"
        ] do
      assert_raise ArgumentError, ~r/K_COMMS_LOCAL_RELEASE_HOST must be an exact/, fn ->
        LocalReleaseGuard.validate!(options(local_release_host: invalid))
      end
    end
  end

  test "an explicit loopback release host is exact while the unset default stays compatible" do
    assert :ok =
             LocalReleaseGuard.validate!(
               options(
                 local_release_host: "localhost",
                 phx_host: "localhost",
                 public_app_url: "http://localhost:4188",
                 livekit_server_url: "ws://localhost:7980",
                 s3_public_endpoint: "http://localhost:5900",
                 cors_origins: ["http://localhost:4188"],
                 csp_connect_sources: ["'self'", "ws://localhost:7980"]
               )
             )

    assert :ok = LocalReleaseGuard.validate!(options(local_release_host: nil))
  end

  test "requires both the local-release and development-adapter gates" do
    assert :ok = LocalReleaseGuard.validate!(enabled?: false)

    assert :ok =
             LocalReleaseGuard.validate!(options(enabled?: false, development_adapters?: false))

    assert_raise ArgumentError, ~r/requires ALLOW_DEVELOPMENT_ADAPTERS=true/, fn ->
      LocalReleaseGuard.validate!(options(development_adapters?: false))
    end
  end

  test "rejects one-shot and media-disabled attempts to use the exception" do
    assert_raise ArgumentError, ~r/only for an application runtime/, fn ->
      LocalReleaseGuard.validate!(options(runtime_purpose: "one_shot"))
    end

    assert_raise ArgumentError, ~r/requires AUDIO_PROVIDER_MODE=livekit/, fn ->
      LocalReleaseGuard.validate!(options(audio_provider_mode: "disabled"))
    end
  end

  test "rejects non-loopback application and browser media origins" do
    assert_raise ArgumentError,
                 ~r/PHX_HOST must exactly match localhost or a loopback address/,
                 fn ->
                   LocalReleaseGuard.validate!(options(phx_host: "comms.example.com"))
                 end

    assert_raise ArgumentError, ~r/PUBLIC_APP_URL must be an exact/, fn ->
      LocalReleaseGuard.validate!(options(public_app_url: "http://192.0.2.10:4188"))
    end

    assert_raise ArgumentError, ~r/LIVEKIT_SERVER_URL must be an exact/, fn ->
      LocalReleaseGuard.validate!(options(livekit_server_url: "ws://media.example.com:7980"))
    end
  end

  test "rejects broader or incomplete internal LiveKit API endpoints" do
    for invalid <- [
          "http://livekit",
          "http://livekit:7881",
          "http://localhost:7880",
          "https://livekit:7880",
          "http://livekit:7880/path"
        ] do
      assert_raise ArgumentError, ~r/LIVEKIT_API_URL must be an exact/, fn ->
        LocalReleaseGuard.validate!(options(livekit_api_url: invalid))
      end
    end
  end

  test "rejects non-loopback object, CORS, and CSP endpoints" do
    assert_raise ArgumentError, ~r/S3_PUBLIC_ENDPOINT must be an exact/, fn ->
      LocalReleaseGuard.validate!(options(s3_public_endpoint: "http://objects.example.com:5900"))
    end

    assert_raise ArgumentError, ~r/CORS_ORIGINS must be an exact/, fn ->
      LocalReleaseGuard.validate!(
        options(cors_origins: ["http://127.0.0.1:4188", "https://example.com"])
      )
    end

    assert_raise ArgumentError, ~r/CSP_CONNECT_SOURCES must be an exact/, fn ->
      LocalReleaseGuard.validate!(
        options(csp_connect_sources: ["'self'", "wss://media.example.com"])
      )
    end
  end
end
