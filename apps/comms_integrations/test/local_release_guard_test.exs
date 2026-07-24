defmodule CommsIntegrations.LocalReleaseGuardTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.LocalReleaseGuard

  test "accepts only the explicit loopback Compose qualification topology" do
    assert :ok = LocalReleaseGuard.validate!(options())
  end

  test "requires both the local-release and development-adapter gates" do
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
    assert_raise ArgumentError, ~r/PHX_HOST must be localhost or a loopback address/, fn ->
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

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        enabled?: true,
        development_adapters?: true,
        runtime_purpose: "application",
        audio_provider_mode: "livekit",
        phx_host: "127.0.0.1",
        public_app_url: "http://127.0.0.1:4188",
        livekit_server_url: "ws://127.0.0.1:7980",
        livekit_api_url: "http://livekit:7880",
        s3_public_endpoint: "http://127.0.0.1:5900",
        cors_origins: ["http://127.0.0.1:4188", "http://localhost:4188"],
        csp_connect_sources: [
          "'self'",
          "http://127.0.0.1:4188",
          "ws://127.0.0.1:4188",
          "ws://127.0.0.1:7980",
          "http://127.0.0.1:5900"
        ]
      ],
      overrides
    )
  end
end
