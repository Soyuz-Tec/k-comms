defmodule CommsIntegrations.LocalReleaseGuardTestOptions do
  @moduledoc false

  def options(overrides \\ []) do
    Keyword.merge(
      [
        enabled?: true,
        development_adapters?: true,
        role: "all",
        runtime_purpose: "application",
        allow_bootstrap?: false,
        audio_provider_mode: "livekit",
        livekit_topology: "local_sidecar",
        managed_livekit_confirmation: nil,
        local_release_host: nil,
        instant_room_tenant_slug: "k-comms-development",
        qualification_app_origin: nil,
        qualification_app_confirmation: nil,
        qualification_share_origin: nil,
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

  def lan_options(overrides \\ []) do
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

  def qualification_options(origin) do
    lan_options(
      role: "edge",
      allow_bootstrap?: false,
      instant_room_tenant_slug: "k-comms-qualification-0123456789abcdef0123456789abcdef",
      qualification_app_origin: origin,
      qualification_app_confirmation: "local-release-qualification-app-v1",
      qualification_share_origin: "https://comms.avayaworks.com",
      cors_origins: [origin]
    )
  end

  def trusted_edge_options(overrides \\ []) do
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
