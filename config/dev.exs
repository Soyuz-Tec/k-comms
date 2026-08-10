import Config

public_app_url = System.get_env("PUBLIC_APP_URL", "http://localhost:5173")

config :comms_core, CommsCore.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/k_comms_dev"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :comms_core,
  audio_participant_eviction_enforcement_seconds:
    String.to_integer(System.get_env("AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS", "660")),
  instant_rooms_enabled:
    System.get_env("INSTANT_ROOMS_ENABLED", "false")
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("true"),
  instant_room_tenant_slug:
    System.get_env("INSTANT_ROOM_TENANT_SLUG", "k-comms-development")
    |> String.trim(),
  instant_room_guest_idle_ttl_seconds:
    String.to_integer(System.get_env("INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS", "3600")),
  instant_room_registered_idle_ttl_seconds:
    String.to_integer(System.get_env("INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS", "86400")),
  instant_room_presence_heartbeat_seconds:
    String.to_integer(System.get_env("INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS", "30")),
  instant_room_presence_lease_seconds:
    String.to_integer(System.get_env("INSTANT_ROOM_PRESENCE_LEASE_SECONDS", "90")),
  instant_room_reconnect_grace_seconds:
    String.to_integer(System.get_env("INSTANT_ROOM_RECONNECT_GRACE_SECONDS", "90")),
  instant_room_max_participants:
    String.to_integer(System.get_env("INSTANT_ROOM_MAX_PARTICIPANTS", "25")),
  webhook_secret_encryption_key: "development-only-webhook-key-32b",
  push_subscription_encryption_key: "push-subscription-test-key-32byt",
  push_delivery_status: :degraded,
  web_push_vapid_public_key:
    "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo",
  password_recovery_signing_key: "development-only-password-recovery-signing-key",
  password_recovery_ttl_seconds: 1_800,
  password_recovery_retention_seconds: 2_592_000,
  public_app_url: public_app_url

config :comms_integrations,
  allow_insecure_local_object_storage: true,
  # Development signalling and SFU control default to ws://127.0.0.1 and
  # http://livekit; both are refused unless this gate is explicitly on.
  allow_insecure_local_media: true,
  audio_provider_mode: System.get_env("AUDIO_PROVIDER_MODE", "livekit"),
  livekit_server_url: System.get_env("LIVEKIT_SERVER_URL", "ws://127.0.0.1:7880"),
  livekit_api_url: System.get_env("LIVEKIT_API_URL", "http://livekit:7880"),
  livekit_api_key: System.get_env("LIVEKIT_API_KEY", "kcomms-local-api-key"),
  livekit_api_secret:
    System.get_env("LIVEKIT_API_SECRET", "kcomms-local-api-secret-not-for-prod"),
  audio_token_ttl_seconds: String.to_integer(System.get_env("AUDIO_TOKEN_TTL_SECONDS", "300")),
  notification_adapter: CommsIntegrations.Notifications.Log,
  scanner_adapter: CommsIntegrations.Scanner.AllowAll,
  webhook_adapter: CommsIntegrations.Webhooks.Log,
  webhook_allowed_hosts: ["webhook.local"],
  webhook_http: [allowed_hosts: ["webhook.local"], allowed_ports: [443], timeout_ms: 10_000]

config :comms_web,
  allow_bootstrap: true,
  direct_audio_p2p_enabled:
    System.get_env("DIRECT_AUDIO_P2P_ENABLED", "true")
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("true"),
  direct_audio_stun_urls:
    System.get_env("DIRECT_AUDIO_STUN_URLS", "stun:stun.cloudflare.com:3478")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1),
  instant_room_creation_rate_limits_enabled: false,
  public_share_origin: public_app_url,
  access_token_ttl_seconds: 3_600,
  metrics_allow_unauthenticated: true,
  csp_connect_sources:
    System.get_env(
      "CSP_CONNECT_SOURCES",
      "'self' http://localhost:4000 ws://localhost:4000 http://localhost:9000 ws://127.0.0.1:7880"
    )
    |> String.split(" ", trim: true)

config :comms_web, CommsWeb.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: String.to_integer(System.get_env("PORT", "4000")),
    websocket_options: [
      max_frame_size: 1_048_576,
      max_fragmented_message_size: 1_048_576
    ]
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    System.get_env(
      "SECRET_KEY_BASE",
      "6KCL3mQG1j2dQME5wy6R5A0j2xzx9azR6fCP5MwlENiB3IKd1k7A5QfP1QW5m3RF"
    ),
  watchers: []

config :comms_integrations,
  s3: [
    scheme: "http",
    host: System.get_env("S3_PUBLIC_HOST", "localhost"),
    port: String.to_integer(System.get_env("S3_PUBLIC_PORT", "9000")),
    internal_scheme: System.get_env("S3_INTERNAL_SCHEME", "http"),
    internal_host: System.get_env("S3_INTERNAL_HOST", "localhost"),
    internal_port: String.to_integer(System.get_env("S3_INTERNAL_PORT", "9000")),
    bucket: System.get_env("S3_BUCKET", "k-comms-dev"),
    region: System.get_env("S3_REGION", "us-east-1"),
    access_key_id: System.get_env("S3_ACCESS_KEY_ID", "kcomms"),
    secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY", "change-this-local-password"),
    expires_in: 900
  ]
