import Config

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is required"
  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE is required"
  role = System.get_env("K_COMMS_ROLE", "all")

  config :comms_core, CommsCore.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "20"))

  config :comms_core, Oban,
    queues: if(role == "edge", do: false, else: [default: 20, notifications: 20, webhooks: 20, media: 10, outbox: 20])

  config :comms_web, CommsWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST", "example.invalid"), port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base,
    server: role in ["all", "edge"]
end
