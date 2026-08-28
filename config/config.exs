import Config

config :comms_core,
  ecto_repos: [CommsCore.Repo],
  conversation_call_lifecycle_adapter: CommsCore.AudioCalls,
  conversation_whiteboard_reclamation_adapter: CommsCore.Whiteboards,
  identity_conversation_bootstrap_adapter: CommsCore.Conversations,
  identity_call_lifecycle_adapter: CommsCore.AudioCalls,
  identity_notification_adapter: CommsCore.Notifications,
  tenant_call_lifecycle_adapter: CommsCore.AudioCalls,
  tenant_authorization_actor_adapter: CommsCore.Accounts,
  tenant_identity_access_adapter: CommsCore.Accounts,
  tenant_invitation_identity_adapter: CommsCore.Accounts,
  notification_availability_notifier: CommsWeb.NotificationAvailabilityNotifier,
  audio_participant_eviction_enforcement_seconds: 660,
  instant_rooms_enabled: false,
  instant_room_tenant_slug: nil,
  instant_room_guest_idle_ttl_seconds: 3_600,
  instant_room_registered_idle_ttl_seconds: 86_400,
  instant_room_presence_heartbeat_seconds: 30,
  instant_room_presence_lease_seconds: 90,
  instant_room_reconnect_grace_seconds: 90,
  instant_room_max_participants: 25,
  job_workers: [
    audio_call_expiry: CommsWorkers.AudioCallExpiryWorker,
    audio_participant_eviction: CommsWorkers.AudioParticipantEvictionWorker,
    attachment_abandon: CommsWorkers.AttachmentAbandonWorker,
    attachment_abandon_reconciler: CommsWorkers.AttachmentCleanupReconcilerWorker,
    attachment_scan: CommsWorkers.AttachmentWorker,
    deletion: CommsWorkers.DeletionWorker,
    ephemeral_room_lifecycle: CommsWorkers.EphemeralRoomLifecycleWorker,
    ephemeral_room_reconciler: CommsWorkers.EphemeralRoomReconcilerWorker,
    guest_admission_expiry: CommsWorkers.GuestAdmissionExpiryWorker,
    notification_delivery: CommsWorkers.NotificationWorker,
    outbox_publication: CommsWorkers.OutboxWorker,
    retention: CommsWorkers.RetentionWorker,
    webhook_delivery: CommsWorkers.WebhookWorker
  ],
  attachment_cleanup_grace_seconds: 300,
  attachment_cleanup_claim_timeout_seconds: 900,
  attachment_cleanup_reconcile_limit: 100,
  push_delivery_status: :unavailable,
  session_ttl_seconds: 2_592_000,
  session_absolute_ttl_seconds: 2_592_000

config :comms_core, CommsCore.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [type: :binary_id]

config :comms_core, Oban,
  repo: CommsCore.Repo,
  queues: [
    default: 10,
    lifecycle: 10,
    notifications: 10,
    webhooks: 10,
    media: 5,
    outbox: 10
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", CommsWorkers.AttachmentCleanupReconcilerWorker},
       {"* * * * *", CommsWorkers.EphemeralRoomReconcilerWorker}
     ]}
  ]

config :comms_integrations,
  allow_insecure_local_object_storage: false,
  allow_insecure_local_media: false,
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
  direct_audio_join_rate_limit: 8,
  direct_audio_p2p_enabled: false,
  direct_audio_signal_byte_limit: 262_144,
  direct_audio_signal_rate_limit: 240,
  direct_audio_stun_urls: ["stun:stun.cloudflare.com:3478"],
  immersive_mode_enabled: false,
  instant_room_creation_rate_limits_enabled: true,
  insecure_lan_release: false,
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

config :phoenix, :filter_parameters, [
  "access_token",
  "authorization",
  "conversion_verification_code",
  "current_password",
  "new_password",
  "password",
  "refresh_token",
  "secret",
  "socket_ticket",
  "token",
  "verification_code"
]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :tenant_id, :actor_id, :conversation_id, :job_id]

import_config "#{config_env()}.exs"
