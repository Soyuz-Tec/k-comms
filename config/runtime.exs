import Config

parse_endpoint = fn value ->
  uri = URI.parse(value)

  {uri.scheme || "http", uri.host || "localhost",
   uri.port || if(uri.scheme == "https", do: 443, else: 80)}
end

parse_keyring = fn value, environment_name ->
  case value do
    nil ->
      nil

    "" ->
      nil

    encoded ->
      encoded
      |> String.split(",", trim: true)
      |> Enum.map(fn entry ->
        case String.split(entry, ":", parts: 2) do
          [key_id, key] when key_id != "" and key != "" -> {key_id, key}
          _ -> raise "#{environment_name} must use key_id:base64 entries"
        end
      end)
      |> Map.new()
  end
end

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  role = System.get_env("K_COMMS_ROLE", "all")
  runtime_purpose = System.get_env("K_COMMS_RUNTIME_PURPOSE", "application")
  host = System.get_env("PHX_HOST", "example.invalid")
  port = String.to_integer(System.get_env("PORT", "4000"))
  cluster_query = System.get_env("CLUSTER_DNS_QUERY")
  public_app_url = System.fetch_env!("PUBLIC_APP_URL")
  public_app_uri = URI.parse(public_app_url)
  recovery_signing_key = System.fetch_env!("PASSWORD_RECOVERY_SIGNING_KEY")

  unless runtime_purpose in ["application", "one_shot"] do
    raise "K_COMMS_RUNTIME_PURPOSE must be application or one_shot"
  end

  unless public_app_uri.scheme == "https" and is_binary(public_app_uri.host) and
           public_app_uri.path in [nil, "", "/"] and is_nil(public_app_uri.userinfo) and
           is_nil(public_app_uri.query) and is_nil(public_app_uri.fragment) do
    raise "PUBLIC_APP_URL must be an absolute HTTPS origin in production"
  end

  if byte_size(recovery_signing_key) < 32 do
    raise "PASSWORD_RECOVERY_SIGNING_KEY must contain at least 32 bytes"
  end

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
    session_ttl_seconds: String.to_integer(System.get_env("SESSION_TTL_SECONDS", "2592000")),
    password_recovery_signing_key: recovery_signing_key,
    password_recovery_ttl_seconds:
      String.to_integer(System.get_env("PASSWORD_RECOVERY_TTL_SECONDS", "1800")),
    password_recovery_retention_seconds:
      String.to_integer(System.get_env("PASSWORD_RECOVERY_RETENTION_SECONDS", "2592000")),
    password_recovery_min_response_ms:
      String.to_integer(System.get_env("PASSWORD_RECOVERY_MIN_RESPONSE_MS", "500")),
    password_recovery_jitter_ms:
      String.to_integer(System.get_env("PASSWORD_RECOVERY_JITTER_MS", "50")),
    public_app_url: public_app_url,
    platform_role_management_secret: System.get_env("K_COMMS_PLATFORM_ROLE_MANAGEMENT_SECRET"),
    allow_bootstrap_platform_role:
      System.get_env("K_COMMS_ALLOW_BOOTSTRAP_PLATFORM_ROLE", "false") == "true",
    bootstrap_platform_role: System.get_env("K_COMMS_BOOTSTRAP_PLATFORM_ROLE"),
    webhook_secret_encryption_key: System.get_env("WEBHOOK_SECRET_ENCRYPTION_KEY"),
    webhook_secret_encryption_key_id:
      System.get_env("WEBHOOK_SECRET_ENCRYPTION_KEY_ID", "primary"),
    webhook_secret_encryption_keys:
      parse_keyring.(
        System.get_env("WEBHOOK_SECRET_ENCRYPTION_KEYS"),
        "WEBHOOK_SECRET_ENCRYPTION_KEYS"
      ),
    push_subscription_encryption_key: System.get_env("PUSH_SUBSCRIPTION_ENCRYPTION_KEY"),
    push_subscription_encryption_key_id:
      System.get_env("PUSH_SUBSCRIPTION_ENCRYPTION_KEY_ID", "primary"),
    push_subscription_encryption_keys:
      parse_keyring.(
        System.get_env("PUSH_SUBSCRIPTION_ENCRYPTION_KEYS"),
        "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS"
      ),
    web_push_vapid_public_key: System.get_env("WEB_PUSH_VAPID_PUBLIC_KEY")

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

  cors_origins =
    System.get_env("CORS_ORIGINS", "https://#{host}")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  trusted_proxy_cidrs =
    System.get_env("TRUSTED_PROXY_CIDRS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :comms_web,
    allow_bootstrap: System.get_env("ALLOW_BOOTSTRAP", "false") == "true",
    hsts: System.get_env("HSTS_ENABLED", "true") == "true",
    metrics_allow_unauthenticated: false,
    metrics_bearer_token: System.get_env("METRICS_BEARER_TOKEN"),
    csp_connect_sources:
      System.get_env("CSP_CONNECT_SOURCES", "'self' wss://#{host} https://#{host}")
      |> String.split(" ", trim: true),
    access_token_ttl_seconds:
      String.to_integer(System.get_env("ACCESS_TOKEN_TTL_SECONDS", "900")),
    cors_origins: cors_origins,
    trusted_proxy_cidrs: trusted_proxy_cidrs

  config :comms_web, CommsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    check_origin: cors_origins,
    server: role in ["all", "edge"]

  {s3_scheme, s3_host, s3_port} =
    parse_endpoint.(System.get_env("S3_PUBLIC_ENDPOINT", "http://localhost:9000"))

  {s3_internal_scheme, s3_internal_host, s3_internal_port} =
    parse_endpoint.(
      System.get_env("S3_INTERNAL_ENDPOINT", "#{s3_scheme}://#{s3_host}:#{s3_port}")
    )

  notification_mode = System.get_env("NOTIFICATION_PROVIDER_MODE", "disabled")
  scanner_mode = System.get_env("ATTACHMENT_SCANNER_MODE", "disabled")
  webhook_mode = System.get_env("WEBHOOK_PROVIDER_MODE", "disabled")
  development_adapters? = System.get_env("ALLOW_DEVELOPMENT_ADAPTERS", "false") == "true"

  webhook_allowed_hosts =
    System.get_env("WEBHOOK_ALLOWED_HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&(String.trim(&1) |> String.trim_trailing(".") |> String.downcase()))

  notification_allowed_hosts =
    System.get_env("NOTIFICATION_PROVIDER_ALLOWED_HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&(String.trim(&1) |> String.trim_trailing(".") |> String.downcase()))

  scanner_allowed_hosts =
    System.get_env("ATTACHMENT_SCANNER_ALLOWED_HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&(String.trim(&1) |> String.trim_trailing(".") |> String.downcase()))

  notification_http = [
    endpoint: System.get_env("NOTIFICATION_PROVIDER_ENDPOINT"),
    token: System.get_env("NOTIFICATION_PROVIDER_TOKEN"),
    provider_name: System.get_env("NOTIFICATION_PROVIDER_NAME"),
    allowed_hosts: notification_allowed_hosts,
    allowed_ports: [443],
    timeout_ms: String.to_integer(System.get_env("NOTIFICATION_PROVIDER_TIMEOUT_MS", "10000"))
  ]

  scanner_http = [
    endpoint: System.get_env("ATTACHMENT_SCANNER_ENDPOINT"),
    token: System.get_env("ATTACHMENT_SCANNER_TOKEN"),
    provider_name: System.get_env("ATTACHMENT_SCANNER_PROVIDER_NAME"),
    allowed_hosts: scanner_allowed_hosts,
    allowed_ports: [443],
    timeout_ms: String.to_integer(System.get_env("ATTACHMENT_SCANNER_TIMEOUT_MS", "30000"))
  ]

  webhook_http = [
    allowed_hosts: webhook_allowed_hosts,
    allowed_ports: [443],
    timeout_ms: String.to_integer(System.get_env("WEBHOOK_TIMEOUT_MS", "10000"))
  ]

  provider_runtime =
    CommsIntegrations.RuntimeConfig.validate!(
      notification_mode: notification_mode,
      scanner_mode: scanner_mode,
      webhook_mode: webhook_mode,
      development_adapters?: development_adapters?,
      provider_preflight?: runtime_purpose == "application",
      notification_http: notification_http,
      scanner_http: scanner_http,
      webhook_http: webhook_http
    )

  config :comms_core,
    push_delivery_status: provider_runtime.notification_delivery_status

  config :comms_integrations,
    object_storage_adapter: CommsIntegrations.ObjectStorage.S3,
    notification_adapter: provider_runtime.notification_adapter,
    notification_http: notification_http,
    scanner_adapter: provider_runtime.scanner_adapter,
    scanner_http: scanner_http,
    webhook_adapter: provider_runtime.webhook_adapter,
    webhook_allowed_hosts: webhook_allowed_hosts,
    webhook_http: webhook_http,
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
