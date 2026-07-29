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
      {keys, _materials} =
        encoded
        |> String.split(",", trim: true)
        |> Enum.reduce({%{}, MapSet.new()}, fn entry, {keys, materials} ->
          {key_id, key} =
            case String.split(entry, ":", parts: 2) do
              [key_id, key] when key_id != "" and key != "" -> {key_id, key}
              _ -> raise "#{environment_name} must use key_id:base64 entries"
            end

          unless Regex.match?(~r/^[A-Za-z0-9_.-]{1,64}$/, key_id) do
            raise "#{environment_name} contains an invalid key identifier"
          end

          if Map.has_key?(keys, key_id) do
            raise "#{environment_name} contains duplicate key identifiers"
          end

          material =
            case Base.decode64(key) do
              {:ok, decoded} when byte_size(decoded) == 32 -> decoded
              _ -> raise "#{environment_name} entries must encode exactly 32 bytes"
            end

          if MapSet.member?(materials, material) do
            raise "#{environment_name} contains duplicate key material"
          end

          {Map.put(keys, key_id, key), MapSet.put(materials, material)}
        end)

      keys
  end
end

decode_runtime_key = fn value, environment_name ->
  cond do
    not is_binary(value) ->
      nil

    byte_size(value) == 32 ->
      value

    true ->
      case Base.decode64(value) do
        {:ok, decoded} when byte_size(decoded) == 32 -> decoded
        _ -> raise "#{environment_name} must be exactly 32 bytes or Base64 encoding of 32 bytes"
      end
  end
end

parse_bounded_integer = fn value, environment_name, allowed_range ->
  case Integer.parse(value) do
    {parsed, ""} ->
      unless parsed in allowed_range do
        raise "#{environment_name} must be between #{allowed_range.first} and #{allowed_range.last}"
      end

      parsed

    _ ->
      raise "#{environment_name} must be an integer"
  end
end

parse_boolean = fn value, environment_name ->
  case value |> to_string() |> String.trim() |> String.downcase() do
    "true" -> true
    "false" -> false
    _ -> raise "#{environment_name} must be true or false"
  end
end

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  database_url
  |> URI.parse()
  |> Map.get(:query)
  |> case do
    nil ->
      :ok

    query ->
      if Enum.any?(URI.query_decoder(query), fn {key, _value} ->
           String.downcase(key) == "ssl"
         end) do
        raise "DATABASE_URL must not override the runtime TLS policy with an ssl query parameter"
      end
  end

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE must contain at least 64 bytes"
  end

  role = System.get_env("K_COMMS_ROLE", "all")
  runtime_purpose = System.get_env("K_COMMS_RUNTIME_PURPOSE", "application")
  development_adapters? = System.get_env("ALLOW_DEVELOPMENT_ADAPTERS", "false") == "true"
  local_release? = System.get_env("K_COMMS_LOCAL_RELEASE", "false") == "true"
  release_exposure_mode = System.get_env("K_COMMS_RELEASE_EXPOSURE_MODE")
  livekit_topology = System.get_env("K_COMMS_LIVEKIT_TOPOLOGY", "local_sidecar")

  managed_livekit_confirmation =
    case System.get_env("K_COMMS_MANAGED_LIVEKIT_CONFIRMATION") do
      nil -> nil
      "" -> nil
      value -> value
    end

  trusted_edge_confirmation =
    case System.get_env("K_COMMS_TRUSTED_EDGE_CONFIRMATION") do
      nil -> nil
      "" -> nil
      value -> value
    end

  trusted_edge_release? =
    local_release? and release_exposure_mode == "cloudflare_trusted_edge"

  allow_bootstrap? = System.get_env("ALLOW_BOOTSTRAP", "false") == "true"
  qualification_app_origin = System.get_env("K_COMMS_QUALIFICATION_APP_ORIGIN")

  qualification_app_confirmation =
    System.get_env("K_COMMS_QUALIFICATION_APP_CONFIRMATION")

  qualification_share_origin =
    System.get_env("K_COMMS_QUALIFICATION_SHARE_ORIGIN")

  local_release_host =
    case System.get_env("K_COMMS_LOCAL_RELEASE_HOST") do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: value
    end

  instant_rooms_enabled? =
    parse_boolean.(
      System.get_env("INSTANT_ROOMS_ENABLED", "false"),
      "INSTANT_ROOMS_ENABLED"
    )

  instant_room_tenant_slug =
    case System.get_env("INSTANT_ROOM_TENANT_SLUG") do
      nil -> nil
      value -> String.trim(value)
    end

  instant_room_guest_idle_ttl_seconds =
    parse_bounded_integer.(
      System.get_env("INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS", "3600"),
      "INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS",
      60..3_600
    )

  instant_room_registered_idle_ttl_seconds =
    parse_bounded_integer.(
      System.get_env("INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS", "86400"),
      "INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS",
      60..86_400
    )

  instant_room_presence_heartbeat_seconds =
    parse_bounded_integer.(
      System.get_env("INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS", "30"),
      "INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS",
      1..60
    )

  instant_room_presence_lease_seconds =
    parse_bounded_integer.(
      System.get_env("INSTANT_ROOM_PRESENCE_LEASE_SECONDS", "90"),
      "INSTANT_ROOM_PRESENCE_LEASE_SECONDS",
      3..300
    )

  instant_room_reconnect_grace_seconds =
    parse_bounded_integer.(
      System.get_env("INSTANT_ROOM_RECONNECT_GRACE_SECONDS", "90"),
      "INSTANT_ROOM_RECONNECT_GRACE_SECONDS",
      3..300
    )

  instant_room_max_participants =
    parse_bounded_integer.(
      System.get_env("INSTANT_ROOM_MAX_PARTICIPANTS", "25"),
      "INSTANT_ROOM_MAX_PARTICIPANTS",
      2..25
    )

  if instant_room_presence_lease_seconds < instant_room_presence_heartbeat_seconds * 3 do
    raise "INSTANT_ROOM_PRESENCE_LEASE_SECONDS must be at least three times " <>
            "INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS"
  end

  if instant_room_reconnect_grace_seconds < instant_room_presence_lease_seconds do
    raise "INSTANT_ROOM_RECONNECT_GRACE_SECONDS must be greater than or equal to " <>
            "INSTANT_ROOM_PRESENCE_LEASE_SECONDS"
  end

  if instant_rooms_enabled? do
    unless is_binary(instant_room_tenant_slug) and
             byte_size(instant_room_tenant_slug) in 2..80 and
             Regex.match?(
               ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
               instant_room_tenant_slug
             ) do
      raise "INSTANT_ROOM_TENANT_SLUG must be a configured lowercase tenant slug " <>
              "when instant rooms are enabled"
    end

    unless local_release? or
             {instant_room_guest_idle_ttl_seconds, instant_room_registered_idle_ttl_seconds,
              instant_room_presence_heartbeat_seconds, instant_room_presence_lease_seconds,
              instant_room_reconnect_grace_seconds, instant_room_max_participants} ==
               {3_600, 86_400, 30, 90, 90, 25} do
      raise "production instant-room lifecycle values must be exactly " <>
              "guest_idle=3600, registered_idle=86400, heartbeat=30, lease=90, " <>
              "reconnect_grace=90, max_participants=25"
    end
  end

  audio_provider_mode =
    System.get_env("AUDIO_PROVIDER_MODE", "disabled") |> String.trim() |> String.downcase()

  livekit_server_url = System.get_env("LIVEKIT_SERVER_URL")
  livekit_api_url = System.get_env("LIVEKIT_API_URL")
  livekit_api_key = System.get_env("LIVEKIT_API_KEY")
  livekit_api_secret = System.get_env("LIVEKIT_API_SECRET")

  audio_token_ttl_seconds =
    case Integer.parse(System.get_env("AUDIO_TOKEN_TTL_SECONDS", "300")) do
      {value, ""} -> value
      _ -> raise "AUDIO_TOKEN_TTL_SECONDS must be an integer"
    end

  audio_participant_eviction_enforcement_seconds =
    case Integer.parse(System.get_env("AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS", "660")) do
      {value, ""} -> value
      _ -> raise "AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS must be an integer"
    end

  ice_url_list = fn name ->
    name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  stun_urls = ice_url_list.("STUN_URLS")
  turn_urls = ice_url_list.("TURN_URLS")
  turn_static_auth_secret = System.get_env("TURN_STATIC_AUTH_SECRET")

  turn_credential_ttl_seconds =
    case Integer.parse(System.get_env("TURN_CREDENTIAL_TTL_SECONDS", "3600")) do
      {value, ""} -> value
      _ -> raise "TURN_CREDENTIAL_TTL_SECONDS must be an integer"
    end

  if turn_urls != [] and (is_nil(turn_static_auth_secret) or turn_static_auth_secret == "") do
    raise "TURN_STATIC_AUTH_SECRET is required when TURN_URLS is set"
  end

  host = System.get_env("PHX_HOST", "example.invalid")
  port = String.to_integer(System.get_env("PORT", "4000"))
  cluster_query = System.get_env("CLUSTER_DNS_QUERY")
  public_app_url = System.fetch_env!("PUBLIC_APP_URL")
  public_app_uri = URI.parse(public_app_url)
  recovery_signing_key = System.fetch_env!("PASSWORD_RECOVERY_SIGNING_KEY")

  webhook_secret_encryption_key_id =
    System.get_env("WEBHOOK_SECRET_ENCRYPTION_KEY_ID", "primary")

  webhook_secret_encryption_keys =
    parse_keyring.(
      System.get_env("WEBHOOK_SECRET_ENCRYPTION_KEYS"),
      "WEBHOOK_SECRET_ENCRYPTION_KEYS"
    )

  push_subscription_encryption_key_id =
    System.get_env("PUSH_SUBSCRIPTION_ENCRYPTION_KEY_ID", "primary")

  push_subscription_encryption_keys =
    parse_keyring.(
      System.get_env("PUSH_SUBSCRIPTION_ENCRYPTION_KEYS"),
      "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS"
    )

  for {environment_name, current_key_id, keys} <- [
        {
          "WEBHOOK_SECRET_ENCRYPTION_KEYS",
          webhook_secret_encryption_key_id,
          webhook_secret_encryption_keys
        },
        {
          "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS",
          push_subscription_encryption_key_id,
          push_subscription_encryption_keys
        }
      ] do
    unless Regex.match?(~r/^[A-Za-z0-9_.-]{1,64}$/, current_key_id) do
      raise "#{environment_name} active key identifier is invalid"
    end

    if is_map(keys) and not Map.has_key?(keys, current_key_id) do
      raise "#{environment_name} must contain its active key identifier"
    end
  end

  encryption_materials = fn single_key, single_name, keyring ->
    if is_map(keyring) do
      keyring
      |> Map.values()
      |> Enum.map(&decode_runtime_key.(&1, single_name))
      |> MapSet.new()
    else
      case decode_runtime_key.(single_key, single_name) do
        nil -> MapSet.new()
        material -> MapSet.new([material])
      end
    end
  end

  webhook_materials =
    encryption_materials.(
      System.get_env("WEBHOOK_SECRET_ENCRYPTION_KEY"),
      "WEBHOOK_SECRET_ENCRYPTION_KEY",
      webhook_secret_encryption_keys
    )

  push_materials =
    encryption_materials.(
      System.get_env("PUSH_SUBSCRIPTION_ENCRYPTION_KEY"),
      "PUSH_SUBSCRIPTION_ENCRYPTION_KEY",
      push_subscription_encryption_keys
    )

  unless MapSet.disjoint?(webhook_materials, push_materials) do
    raise "encryption key material must not be reused across webhook and push domains"
  end

  unless runtime_purpose in ["application", "one_shot"] do
    raise "K_COMMS_RUNTIME_PURPOSE must be application or one_shot"
  end

  instance_id =
    System.get_env("K_COMMS_INSTANCE_ID") ||
      System.get_env("HOSTNAME") ||
      System.get_env("COMPUTERNAME")

  unless is_binary(instance_id) and String.trim(instance_id) != "" do
    raise "K_COMMS_INSTANCE_ID or the platform hostname must identify this runtime"
  end

  instance_digest =
    :sha256
    |> :crypto.hash(instance_id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)

  role_label =
    role
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> String.slice(0, 12)

  # Runtime configuration is evaluated once per BEAM boot. Every Repo pool
  # connection in this runtime therefore shares this cryptographically random
  # nonce, while a concurrent boot on the same host receives a different one.
  boot_nonce =
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)

  database_application_name =
    "k_comms/#{runtime_purpose}/#{role_label}/#{boot_nonce}/#{instance_digest}"

  unless byte_size(database_application_name) <= 63 do
    raise "PostgreSQL application_name must not exceed 63 bytes"
  end

  {migration_lock_timeout_ms, migration_statement_timeout_ms} =
    if runtime_purpose == "one_shot" do
      lock_timeout_ms =
        parse_bounded_integer.(
          System.get_env("K_COMMS_MIGRATION_LOCK_TIMEOUT_MS", "5000"),
          "K_COMMS_MIGRATION_LOCK_TIMEOUT_MS",
          1_000..30_000
        )

      statement_timeout_ms =
        parse_bounded_integer.(
          System.get_env("K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS", "300000"),
          "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS",
          60_000..900_000
        )

      if statement_timeout_ms <= lock_timeout_ms do
        raise "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS must exceed K_COMMS_MIGRATION_LOCK_TIMEOUT_MS"
      end

      {lock_timeout_ms, statement_timeout_ms}
    else
      {nil, nil}
    end

  unless audio_provider_mode in ["disabled", "livekit"] do
    raise "AUDIO_PROVIDER_MODE must be disabled or livekit"
  end

  csp_connect_sources =
    System.get_env("CSP_CONNECT_SOURCES", "'self' wss://#{host} https://#{host}")
    |> String.split(" ", trim: true)

  cors_origins =
    System.get_env("CORS_ORIGINS", "https://#{host}")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  s3_public_endpoint = System.get_env("S3_PUBLIC_ENDPOINT", "http://localhost:9000")

  hsts? = System.get_env("HSTS_ENABLED", "true") == "true"

  trusted_proxy_cidrs =
    System.get_env("TRUSTED_PROXY_CIDRS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  CommsIntegrations.LocalReleaseGuard.validate!(
    enabled?: local_release?,
    development_adapters?: development_adapters?,
    exposure_mode: release_exposure_mode,
    trusted_edge_confirmation: trusted_edge_confirmation,
    livekit_topology: livekit_topology,
    managed_livekit_confirmation: managed_livekit_confirmation,
    role: role,
    runtime_purpose: runtime_purpose,
    allow_bootstrap?: allow_bootstrap?,
    audio_provider_mode: audio_provider_mode,
    local_release_host: local_release_host,
    instant_room_tenant_slug: instant_room_tenant_slug,
    qualification_app_origin: qualification_app_origin,
    qualification_app_confirmation: qualification_app_confirmation,
    qualification_share_origin: qualification_share_origin,
    phx_host: host,
    public_app_url: public_app_url,
    livekit_server_url: livekit_server_url,
    livekit_api_url: livekit_api_url,
    s3_public_endpoint: s3_public_endpoint,
    cors_origins: cors_origins,
    csp_connect_sources: csp_connect_sources,
    hsts?: hsts?,
    trusted_proxy_cidrs: trusted_proxy_cidrs
  )

  public_share_origin = qualification_share_origin || public_app_url

  if runtime_purpose == "application" and audio_provider_mode == "disabled" and
       not development_adapters? do
    raise "AUDIO_PROVIDER_MODE must be livekit for production application workloads"
  end

  if runtime_purpose == "application" and audio_provider_mode == "livekit" do
    livekit_uri = URI.parse(livekit_server_url || "")
    livekit_api_uri = URI.parse(livekit_api_url || "")

    unless local_release? do
      unless livekit_uri.scheme == "wss" and is_binary(livekit_uri.host) and
               livekit_uri.port in [nil, 443] and livekit_uri.path in [nil, "", "/"] and
               is_nil(livekit_uri.userinfo) and is_nil(livekit_uri.query) and
               is_nil(livekit_uri.fragment) and
               not String.ends_with?(String.downcase(livekit_uri.host), ".invalid") do
        raise "LIVEKIT_SERVER_URL must be an exact WSS origin on port 443 in production"
      end

      unless livekit_api_uri.scheme == "https" and is_binary(livekit_api_uri.host) and
               livekit_api_uri.port in [nil, 443] and
               livekit_api_uri.path in [nil, "", "/"] and
               is_nil(livekit_api_uri.userinfo) and is_nil(livekit_api_uri.query) and
               is_nil(livekit_api_uri.fragment) and
               not String.ends_with?(String.downcase(livekit_api_uri.host), ".invalid") do
        raise "LIVEKIT_API_URL must be an exact HTTPS origin on port 443 in production"
      end
    end

    for {name, value, minimum_bytes} <- [
          {"LIVEKIT_API_KEY", livekit_api_key, 8},
          {"LIVEKIT_API_SECRET", livekit_api_secret, 32}
        ] do
      if not is_binary(value) or byte_size(value) < minimum_bytes or
           Regex.match?(~r/(?:CHANGE_ME|REPLACE_WITH)/i, value) do
        raise "#{name} must contain a non-placeholder secret of at least #{minimum_bytes} bytes"
      end
    end

    unless audio_token_ttl_seconds in 60..300 do
      raise "AUDIO_TOKEN_TTL_SECONDS must be between 60 and 300 seconds"
    end

    unless audio_participant_eviction_enforcement_seconds in 660..1_800 do
      raise "AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS must be between 660 and 1800 seconds"
    end

    if audio_participant_eviction_enforcement_seconds < audio_token_ttl_seconds do
      raise "AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS must be greater than or equal to AUDIO_TOKEN_TTL_SECONDS"
    end

    unless trusted_edge_release? or livekit_server_url in csp_connect_sources do
      raise "CSP_CONNECT_SOURCES must contain the exact LIVEKIT_SERVER_URL origin"
    end
  end

  unless local_release? or
           (public_app_uri.scheme == "https" and is_binary(public_app_uri.host) and
              public_app_uri.path in [nil, "", "/"] and is_nil(public_app_uri.userinfo) and
              is_nil(public_app_uri.query) and is_nil(public_app_uri.fragment)) do
    raise "PUBLIC_APP_URL must be an absolute HTTPS origin in production"
  end

  if byte_size(recovery_signing_key) < 32 do
    raise "PASSWORD_RECOVERY_SIGNING_KEY must contain at least 32 bytes"
  end

  if webhook_secret_encryption_key_id == "legacy" do
    raise "WEBHOOK_SECRET_ENCRYPTION_KEY_ID must not use the reserved legacy identifier"
  end

  if is_map(webhook_secret_encryption_keys) and
       Map.has_key?(webhook_secret_encryption_keys, "legacy") do
    raise "WEBHOOK_SECRET_ENCRYPTION_KEYS must not contain the reserved legacy identifier"
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
    audio_participant_eviction_enforcement_seconds:
      audio_participant_eviction_enforcement_seconds,
    cluster_topologies: topologies,
    instant_rooms_enabled: instant_rooms_enabled?,
    instant_room_tenant_slug: instant_room_tenant_slug,
    instant_room_guest_idle_ttl_seconds: instant_room_guest_idle_ttl_seconds,
    instant_room_registered_idle_ttl_seconds: instant_room_registered_idle_ttl_seconds,
    instant_room_presence_heartbeat_seconds: instant_room_presence_heartbeat_seconds,
    instant_room_presence_lease_seconds: instant_room_presence_lease_seconds,
    instant_room_reconnect_grace_seconds: instant_room_reconnect_grace_seconds,
    instant_room_max_participants: instant_room_max_participants,
    session_ttl_seconds: String.to_integer(System.get_env("SESSION_TTL_SECONDS", "2592000")),
    session_absolute_ttl_seconds:
      String.to_integer(System.get_env("SESSION_ABSOLUTE_TTL_SECONDS", "2592000")),
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
    bootstrap_platform_role_ttl_seconds:
      String.to_integer(System.get_env("K_COMMS_BOOTSTRAP_PLATFORM_ROLE_TTL_SECONDS", "28800")),
    webhook_secret_encryption_key: System.get_env("WEBHOOK_SECRET_ENCRYPTION_KEY"),
    webhook_secret_encryption_key_id: webhook_secret_encryption_key_id,
    webhook_secret_encryption_keys: webhook_secret_encryption_keys,
    push_subscription_encryption_key: System.get_env("PUSH_SUBSCRIPTION_ENCRYPTION_KEY"),
    push_subscription_encryption_key_id: push_subscription_encryption_key_id,
    push_subscription_encryption_keys: push_subscription_encryption_keys,
    web_push_vapid_public_key: System.get_env("WEB_PUSH_VAPID_PUBLIC_KEY")

  database_tls_options =
    CommsCore.DatabaseTLS.repo_options!(
      System.get_env("DATABASE_SSL", "false"),
      System.get_env("DATABASE_SSL_CA_FILE"),
      System.get_env("DATABASE_SSL_SERVER_NAME")
    )

  database_options =
    [
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "20")),
      parameters:
        [
          application_name: database_application_name
        ] ++
          if(runtime_purpose == "one_shot",
            do: [
              lock_timeout: "#{migration_lock_timeout_ms}ms",
              statement_timeout: "#{migration_statement_timeout_ms}ms"
            ],
            else: []
          )
    ] ++ database_tls_options

  config :comms_core, CommsCore.Repo, database_options

  config :comms_core, Oban,
    queues:
      if(role == "edge",
        do: false,
        else: [
          default: 20,
          lifecycle: 20,
          notifications: 20,
          webhooks: 20,
          media: 10,
          outbox: 20
        ]
      )

  config :comms_web,
    allow_bootstrap: allow_bootstrap?,
    public_share_origin: public_share_origin,
    insecure_lan_release:
      local_release? and public_app_uri.scheme == "http" and
        public_app_uri.host not in ["127.0.0.1", "localhost", "::1"],
    secure_transport_required: trusted_edge_release?,
    hsts: hsts?,
    metrics_allow_unauthenticated: false,
    metrics_bearer_token: System.get_env("METRICS_BEARER_TOKEN"),
    csp_connect_sources: csp_connect_sources,
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
    parse_endpoint.(s3_public_endpoint)

  {s3_internal_scheme, s3_internal_host, s3_internal_port} =
    parse_endpoint.(
      System.get_env("S3_INTERNAL_ENDPOINT", "#{s3_scheme}://#{s3_host}:#{s3_port}")
    )

  notification_mode = System.get_env("NOTIFICATION_PROVIDER_MODE", "disabled")
  scanner_mode = System.get_env("ATTACHMENT_SCANNER_MODE", "disabled")
  webhook_mode = System.get_env("WEBHOOK_PROVIDER_MODE", "disabled")

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
    audio_provider_mode: audio_provider_mode,
    livekit_server_url: livekit_server_url,
    livekit_api_url: livekit_api_url,
    livekit_api_key: livekit_api_key,
    livekit_api_secret: livekit_api_secret,
    audio_token_ttl_seconds: audio_token_ttl_seconds,
    stun_urls: stun_urls,
    turn_urls: turn_urls,
    turn_static_auth_secret: turn_static_auth_secret,
    turn_credential_ttl_seconds: turn_credential_ttl_seconds,
    allow_insecure_local_object_storage: local_release? and development_adapters?,
    allow_insecure_local_media: local_release? and development_adapters?,
    insecure_local_object_storage_host:
      if(local_release? and development_adapters?, do: local_release_host, else: nil),
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
      expires_in: String.to_integer(System.get_env("S3_URL_TTL_SECONDS", "900")),
      download_expires_in: String.to_integer(System.get_env("S3_DOWNLOAD_URL_TTL_SECONDS", "120"))
    ]
end
