import Config

config :comms_core,
  ecto_repos: [CommsCore.Repo],
  authorization_adapter: CommsCore.Authorization.DenyAll

config :comms_core, CommsCore.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [type: :binary_id]

config :comms_core, Oban,
  repo: CommsCore.Repo,
  queues: [default: 10, notifications: 10, webhooks: 10, media: 5, outbox: 10],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]

config :comms_integrations,
  notification_adapter: CommsIntegrations.Notifications.DenyAll,
  object_storage_adapter: CommsIntegrations.ObjectStorage.DenyAll,
  webhook_adapter: CommsIntegrations.Webhooks.DenyAll

config :comms_web, generators: [binary_id: true]

config :comms_web, CommsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: CommsWeb.ErrorJSON], layout: false],
  pubsub_server: CommsWeb.PubSub

config :logger, :console,
  format: "$time $metadata[$level] $message
",
  metadata: [:request_id, :tenant_id, :actor_id, :conversation_id, :job_id]

import_config "#{config_env()}.exs"
