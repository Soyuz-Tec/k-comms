import Config

config :comms_core, CommsCore.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/k_comms_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :comms_core, Oban, testing: :manual, queues: false, plugins: false

config :comms_core,
  webhook_secret_encryption_key: "0123456789abcdef0123456789abcdef",
  push_subscription_encryption_key: "push-subscription-test-key-32byt",
  push_delivery_status: :degraded,
  web_push_vapid_public_key:
    "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo",
  password_recovery_signing_key: "test-password-recovery-signing-key-32-bytes-minimum",
  password_recovery_ttl_seconds: 1_800,
  password_recovery_retention_seconds: 2_592_000,
  password_recovery_min_response_ms: 0,
  password_recovery_jitter_ms: 0,
  public_app_url: "http://localhost:5173"

config :comms_integrations,
  allow_insecure_local_object_storage: true,
  notification_adapter: CommsIntegrations.Notifications.Log,
  object_storage_adapter: CommsIntegrations.ObjectStorage.Memory,
  scanner_adapter: CommsIntegrations.Scanner.AllowAll,
  webhook_adapter: CommsIntegrations.Webhooks.Log

config :comms_web,
  allow_bootstrap: true,
  access_token_ttl_seconds: 900,
  auth_adapter: CommsWeb.Auth.Token,
  metrics_allow_unauthenticated: true

config :comms_web, CommsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-at-least-sixty-four-bytes-000000000000000000000000",
  server: false

config :logger, level: :warning
