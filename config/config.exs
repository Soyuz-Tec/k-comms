import Config

config :comms_core,
  ecto_repos: [CommsCore.Repo],
  authorization_adapter: CommsCore.Authorization.Database,
  identity_conversation_bootstrap_adapter: CommsCore.Conversations,
  identity_notification_adapter: CommsCore.Notifications,
  tenant_authorization_actor_adapter: CommsCore.Accounts,
  tenant_identity_access_adapter: CommsCore.Accounts,
  tenant_invitation_identity_adapter: CommsCore.Accounts,
  notification_availability_notifier: CommsWeb.NotificationAvailabilityNotifier,
  audio_participant_eviction_enforcement_seconds: 660,
  job_workers: [
    audio_call_expiry: CommsWorkers.AudioCallExpiryWorker,
    audio_participant_eviction: CommsWorkers.AudioParticipantEvictionWorker,
    attachment_scan: CommsWorkers.AttachmentWorker,
    deletion: CommsWorkers.DeletionWorker,
    notification_delivery: CommsWorkers.NotificationWorker,
    outbox_publication: CommsWorkers.OutboxWorker,
    retention: CommsWorkers.RetentionWorker,
    webhook_delivery: CommsWorkers.WebhookWorker
  ],
  push_delivery_status: :unavailable,
  session_ttl_seconds: 2_592_000,
  session_absolute_ttl_seconds: 2_592_000

config :comms_core, CommsCore.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [type: :binary_id]

config :comms_core, Oban,
  repo: CommsCore.Repo,
  queues: [default: 10, notifications: 10, webhooks: 10, media: 5, outbox: 10],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]

config :comms_integrations,
  allow_insecure_local_object_storage: false,
  audio_provider_mode: "disabled",
  audio_token_ttl_seconds: 300,
  livekit_api_url: nil,
  livekit_api_key: nil,
  livekit_api_secret: nil,
  livekit_server_url: nil,
  notification_adapter: CommsIntegrations.Notifications.Log,
  object_storage_adapter: CommsIntegrations.ObjectStorage.S3,
  scanner_adapter: CommsIntegrations.Scanner.Log,
  webhook_adapter: CommsIntegrations.Webhooks.Http,
  webhook_allowed_hosts: [],
  webhook_http: [allowed_hosts: [], allowed_ports: [443], timeout_ms: 10_000]

config :comms_web,
  generators: [binary_id: true],
  auth_adapter: CommsWeb.Auth.Token,
  access_token_ttl_seconds: 900,
  allow_bootstrap: false,
  hsts: false,
  csp_connect_sources: [
    "'self'",
    "http://localhost:4000",
    "ws://localhost:4000",
    "http://localhost:9000",
    "ws://127.0.0.1:7880"
  ],
  cors_origins: ["http://localhost:5173", "http://127.0.0.1:5173"]

config :comms_web, CommsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: CommsWeb.ErrorJSON], layout: false],
  pubsub_server: CommsWeb.PubSub

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :tenant_id, :actor_id, :conversation_id, :job_id]

import_config "#{config_env()}.exs"
