import Config

parse_endpoint = fn value ->
  uri = URI.parse(value)

  {uri.scheme || "http", uri.host || "localhost",
   uri.port || if(uri.scheme == "https", do: 443, else: 80)}
end

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  role = System.get_env("K_COMMS_ROLE", "all")
  host = System.get_env("PHX_HOST", "example.invalid")
  port = String.to_integer(System.get_env("PORT", "4000"))
  cluster_query = System.get_env("CLUSTER_DNS_QUERY")

  topologies =
    if cluster_query in [nil, ""] do
      []
    else
      [
        k_comms: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [polling_interval: 5_000, query: cluster_query, node_basename: "k_comms"]
        ]
      ]
    end

  config :comms_core,
    cluster_topologies: topologies,
    session_ttl_seconds: String.to_integer(System.get_env("SESSION_TTL_SECONDS", "2592000"))

  config :comms_core, CommsCore.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "20")),
    ssl: System.get_env("DATABASE_SSL", "false") == "true"

  config :comms_core, Oban,
    queues:
      if(role == "edge",
        do: false,
        else: [default: 20, notifications: 20, webhooks: 20, media: 10, outbox: 20]
      )

  config :comms_web,
    allow_bootstrap: System.get_env("ALLOW_BOOTSTRAP", "false") == "true",
    hsts: System.get_env("HSTS_ENABLED", "true") == "true",
    csp_connect_sources:
      System.get_env("CSP_CONNECT_SOURCES", "'self' wss://#{host} https://#{host}")
      |> String.split(" ", trim: true),
    access_token_ttl_seconds:
      String.to_integer(System.get_env("ACCESS_TOKEN_TTL_SECONDS", "900")),
    cors_origins:
      System.get_env("CORS_ORIGINS", "https://#{host}")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

  config :comms_web, CommsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: role in ["all", "edge"]

  {s3_scheme, s3_host, s3_port} =
    parse_endpoint.(System.get_env("S3_PUBLIC_ENDPOINT", "http://localhost:9000"))

  {s3_internal_scheme, s3_internal_host, s3_internal_port} =
    parse_endpoint.(
      System.get_env("S3_INTERNAL_ENDPOINT", "#{s3_scheme}://#{s3_host}:#{s3_port}")
    )

  config :comms_integrations,
    object_storage_adapter: CommsIntegrations.ObjectStorage.S3,
    notification_adapter: CommsIntegrations.Notifications.Log,
    webhook_adapter: CommsIntegrations.Webhooks.Http,
    webhook_allowed_hosts:
      System.get_env("WEBHOOK_ALLOWED_HOSTS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1),
    s3: [
      scheme: s3_scheme,
      host: s3_host,
      port: s3_port,
      internal_scheme: s3_internal_scheme,
      internal_host: s3_internal_host,
      internal_port: s3_internal_port,
      bucket: System.get_env("S3_BUCKET", "k-comms"),
      region: System.get_env("S3_REGION", "us-east-1"),
      access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY"),
      expires_in: String.to_integer(System.get_env("S3_URL_TTL_SECONDS", "900"))
    ]
end
