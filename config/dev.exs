import Config

config :comms_core, CommsCore.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/k_comms_dev"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :comms_web, CommsWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: System.get_env("SECRET_KEY_BASE", "6KCL3mQG1j2dQME5wy6R5A0j2xzx9azR6fCP5MwlENiB3IKd1k7A5QfP1QW5m3RF"),
  watchers: []
