defmodule CommsIntegrations.LocalReleaseGuardTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.LocalReleaseGuard

  test "accepts only the explicit loopback Compose qualification topology" do
    assert :ok = LocalReleaseGuard.validate!(options())
  end

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

  test "accepts one confirmed isolated qualification app CORS origin" do
    for qualification_origin <- [
          "http://127.0.0.1:1024",
          "http://127.0.0.1:45231",
          "http://127.0.0.1:65535"
        ] do
      assert :ok =
               LocalReleaseGuard.validate!(qualification_options(qualification_origin))
    end
  end

  test "accepts qualification CORS without changing a retained loopback public origin" do
    qualification_origin = "http://127.0.0.1:45231"

    assert :ok =
             LocalReleaseGuard.validate!(
               options(
                 role: "edge",
                 instant_room_tenant_slug:
                   "k-comms-qualification-0123456789abcdef0123456789abcdef",
                 qualification_app_origin: qualification_origin,
                 qualification_app_confirmation: "local-release-qualification-app-v1",
                 cors_origins: [qualification_origin]
               )
             )
  end

  test "qualification app mode does not broaden retained release CSP or CORS" do
    qualification_origin = "http://127.0.0.1:45231"
    qualification_options = qualification_options(qualification_origin)

    for cors_origins <- [
          [],
          ["http://192.168.50.25:4188"],
          ["http://127.0.0.1:45232"],
          [qualification_origin, "http://192.168.50.25:4188"],
          [qualification_origin, qualification_origin]
        ] do
      assert_raise ArgumentError, ~r/CORS_ORIGINS must contain exactly/, fn ->
        LocalReleaseGuard.validate!(
          Keyword.put(qualification_options, :cors_origins, cors_origins)
        )
      end
    end

    assert_raise ArgumentError, ~r/CSP_CONNECT_SOURCES must be an exact/, fn ->
      LocalReleaseGuard.validate!(
        Keyword.put(
          qualification_options,
          :csp_connect_sources,
          ["'self'", "ws://192.168.50.25:7980", qualification_origin]
        )
      )
    end
  end

  test "qualification app mode requires every isolation gate" do
    qualification_options = qualification_options("http://127.0.0.1:45231")

    for {field, value, error} <- [
          {:enabled?, false, ~r/requires K_COMMS_LOCAL_RELEASE=true/},
          {:role, "all", ~r/requires K_COMMS_ROLE=edge/},
          {:runtime_purpose, "one_shot", ~r/only for an application runtime/},
          {:allow_bootstrap?, true, ~r/requires ALLOW_BOOTSTRAP=false/},
          {:instant_room_tenant_slug, "k-comms-development",
           ~r/requires INSTANT_ROOM_TENANT_SLUG/},
          {:instant_room_tenant_slug, "k-comms-qualification-0123456789abcdef0123456789abcdeG",
           ~r/requires INSTANT_ROOM_TENANT_SLUG/},
          {:qualification_app_confirmation, nil,
           ~r/K_COMMS_QUALIFICATION_APP_CONFIRMATION must exactly equal/},
          {:qualification_app_confirmation, "local-release-qualification-app-v2",
           ~r/K_COMMS_QUALIFICATION_APP_CONFIRMATION must exactly equal/}
        ] do
      assert_raise ArgumentError, error, fn ->
        LocalReleaseGuard.validate!(Keyword.put(qualification_options, field, value))
      end
    end
  end

  test "qualification app origin is one canonical loopback non-public port" do
    for invalid <- [
          nil,
          "",
          "http://localhost:45231",
          "http://127.0.0.1",
          "http://127.0.0.1:80",
          "http://127.0.0.1:4188",
          "http://127.0.0.1:045231",
          "http://127.0.0.1:45231/",
          "http://127.0.0.1:45231/path",
          "http://127.0.0.1:45231?query=true",
          "http://127.0.0.1:45231#fragment",
          "http://user@127.0.0.1:45231",
          " http://127.0.0.1:45231",
          "http://127.0.0.1:45231 ",
          "http://127.0.0.1:45231\n",
          "https://127.0.0.1:45231",
          "http://127.0.0.1:65536"
        ] do
      assert_raise ArgumentError, ~r/must be an exact canonical/, fn ->
        LocalReleaseGuard.validate!(
          qualification_options(invalid)
          |> Keyword.put(:cors_origins, [invalid])
        )
      end
    end
  end

  test "a partial qualification confirmation fails closed" do
    assert_raise ArgumentError, ~r/K_COMMS_QUALIFICATION_APP_ORIGIN must be an exact/, fn ->
      LocalReleaseGuard.validate!(qualification_options(nil))
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

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        enabled?: true,
        development_adapters?: true,
        role: "all",
        runtime_purpose: "application",
        allow_bootstrap?: false,
        audio_provider_mode: "livekit",
        local_release_host: nil,
        instant_room_tenant_slug: "k-comms-development",
        qualification_app_origin: nil,
        qualification_app_confirmation: nil,
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

  defp lan_options(overrides) do
    host = "192.168.50.25"

    options(
      Keyword.merge(
        [
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
        ],
        overrides
      )
    )
  end

  defp qualification_options(origin) do
    lan_options(
      role: "edge",
      allow_bootstrap?: false,
      instant_room_tenant_slug: "k-comms-qualification-0123456789abcdef0123456789abcdef",
      qualification_app_origin: origin,
      qualification_app_confirmation: "local-release-qualification-app-v1",
      cors_origins: [origin]
    )
  end

  defp trusted_edge_options(overrides \\ []) do
    options(
      Keyword.merge(
        [
          exposure_mode: "cloudflare_trusted_edge",
          trusted_edge_confirmation: "cloudflare-tunnel-v1",
          phx_host: "comms.avayaworks.com",
          public_app_url: "https://comms.avayaworks.com",
          livekit_server_url: "wss://media.avayaworks.com",
          livekit_api_url: "http://livekit:7880",
          s3_public_endpoint: "https://objects.avayaworks.com",
          cors_origins: ["https://comms.avayaworks.com"],
          csp_connect_sources: [
            "'self'",
            "wss://media.avayaworks.com:443",
            "https://objects.avayaworks.com:443"
          ],
          hsts?: true,
          trusted_proxy_cidrs: ["10.89.0.12/32"]
        ],
        overrides
      )
    )
  end
end
