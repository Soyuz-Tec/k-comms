import Config

config :comms_core, CommsCore.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/k_comms_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :comms_core, Oban, testing: :manual, queues: false, plugins: false

config :comms_web, CommsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-at-least-sixty-four-bytes-000000000000000000000000",
  server: false

config :logger, level: :warning
