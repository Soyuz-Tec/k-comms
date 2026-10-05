import Config

# Separate default-off management; bindings contain acquired DIDs/trunk IDs.
# Provider credentials stay in the existing protected server configuration.
phone_provisioning_flag = System.get_env("TELEPHONY_PROVISIONING_ENABLED", "false")

unless phone_provisioning_flag in ["true", "false"],
  do: raise("TELEPHONY_PROVISIONING_ENABLED must be true or false")

phone_provisioning_bindings =
  if phone_provisioning_flag == "true" do
    text = System.get_env("TELEPHONY_PROVISIONING_BINDINGS", "{}")
    result = if byte_size(text) <= 65_536, do: Jason.decode(text), else: :error

    case result do
      {:ok, bindings} when is_map(bindings) ->
        if CommsIntegrations.Telephony.ProvisioningLiveKit.valid_bindings?(bindings),
          do: bindings,
          else:
            raise(
              "TELEPHONY_PROVISIONING_BINDINGS requires exclusive validated tenant trunk and DID bindings"
            )

      _ ->
        raise("TELEPHONY_PROVISIONING_BINDINGS must be bounded valid JSON")
    end
  else
    %{}
  end

config :comms_core, :telephony_provisioning_enabled, phone_provisioning_flag == "true"
config :comms_integrations, :telephony_provisioning_bindings, phone_provisioning_bindings

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

# Optional credentials can be supplied through private regular files mounted
# directly below /run/secrets. Values and paths are never included in failures.
optional_secret = fn name ->
  inline =
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end

  filename =
    case System.get_env(name <> "_FILE") do
      nil -> nil
      "" -> nil
      value -> value
    end

  if inline && filename, do: raise("#{name} and #{name}_FILE are mutually exclusive")

  if filename do
    unless Regex.match?(~r|^/run/secrets/[A-Za-z0-9_.-]{1,128}$|, filename) and
             not String.ends_with?(filename, ["/.", "/.."]) do
      raise "#{name}_FILE must select a private regular file directly in /run/secrets"
    end

    case File.lstat(filename) do
      {:ok, %{type: :regular, size: size, mode: mode}} when size in 1..65_536 ->
        unless Bitwise.band(mode, 0o077) == 0,
          do: raise("#{name}_FILE must deny group and other access")

      _ ->
        raise "#{name}_FILE must select a bounded private regular file"
    end

    case File.read(filename) do
      {:ok, value} when byte_size(value) in 1..65_536 ->
        unless String.valid?(value),
          do: raise("#{name}_FILE must contain a bounded UTF-8 credential")

        credential = String.trim_trailing(value, "\n") |> String.trim_trailing("\r")

        if Regex.match?(~r/[\x00-\x1F\x7F]/u, credential),
          do: raise("#{name}_FILE must contain a single-line credential")

        credential

      _ ->
        raise "#{name}_FILE cannot be read"
    end
  else
    inline
  end
end

csv_values = fn name ->
  values = System.get_env(name, "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  if Enum.any?(values, &(&1 == "")) or length(values) > 100 or
       length(values) != length(Enum.uniq(values)),
     do: raise("#{name} must contain a bounded list of unique nonempty values")

  values
end

https_dns_url? = fn value, origin_only? ->
  if is_binary(value) and byte_size(value) in 1..2_048 do
    uri = URI.parse(value)

    dns? =
      is_binary(uri.host) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/, uri.host) and
        match?({:error, _}, :inet.parse_address(String.to_charlist(uri.host))) and
        not String.ends_with?(String.downcase(uri.host), ".invalid")

    uri.scheme == "https" and uri.port == 443 and dns? and is_nil(uri.userinfo) and
      is_nil(uri.query) and is_nil(uri.fragment) and
      (not origin_only? or uri.path in [nil, "", "/"])
  else
    false
  end
end

parse_json_list = fn value, name ->
  case Jason.decode(value || "[]") do
    {:ok, values} when is_list(values) and length(values) <= 10 ->
      if Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..2_048)) and
           length(Enum.uniq(values)) == length(values),
         do: values,
         else: raise("#{name} must contain unique bounded strings")

    _ ->
      raise "#{name} must be a JSON array with at most ten strings"
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

  # Deployment-side half of immersive eligibility. Off unless a deployment says
  # otherwise, so a rollback of the switch alone retires the surface for every
  # tenant without a client release.
  immersive_mode_enabled? =
    parse_boolean.(
      System.get_env("IMMERSIVE_MODE_ENABLED", "false"),
      "IMMERSIVE_MODE_ENABLED"
    )

  direct_audio_p2p_enabled? =
    parse_boolean.(
      System.get_env("DIRECT_AUDIO_P2P_ENABLED", "true"),
      "DIRECT_AUDIO_P2P_ENABLED"
    )

  direct_audio_stun_urls =
    System.get_env("DIRECT_AUDIO_STUN_URLS", "stun:stun.cloudflare.com:3478")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  if direct_audio_p2p_enabled? and
       (direct_audio_stun_urls == [] or length(direct_audio_stun_urls) > 4 or
          Enum.any?(direct_audio_stun_urls, fn url ->
            not (String.starts_with?(url, "stun:") or String.starts_with?(url, "stuns:")) or
              String.contains?(url, [" ", "\t", "\r", "\n"])
          end)) do
    raise "DIRECT_AUDIO_STUN_URLS must contain one to four comma-separated stun: or stuns: URLs"
  end

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

  telephony_provider_mode =
    System.get_env("TELEPHONY_PROVIDER_MODE", "disabled") |> String.trim() |> String.downcase()

  telephony_ring_timeout_seconds =
    parse_bounded_integer.(
      System.get_env("TELEPHONY_RING_TIMEOUT_SECONDS", "45"),
      "TELEPHONY_RING_TIMEOUT_SECONDS",
      10..90
    )

  telephony_max_duration_seconds =
    parse_bounded_integer.(
      System.get_env("TELEPHONY_MAX_DURATION_SECONDS", "1800"),
      "TELEPHONY_MAX_DURATION_SECONDS",
      60..14_400
    )

  CommsIntegrations.Telephony.Config.validate!(
    mode: telephony_provider_mode,
    audio_mode: audio_provider_mode,
    server_url: livekit_server_url,
    api_url: livekit_api_url,
    api_key: livekit_api_key,
    api_secret: livekit_api_secret,
    ring_timeout_seconds: telephony_ring_timeout_seconds,
    max_duration_seconds: telephony_max_duration_seconds,
    allow_insecure_local_media: local_release? and development_adapters?
  )

  telephony_control_provider = System.get_env("TELEPHONY_CONTROL_PROVIDER", "livekit")

  telephony_control_adapter =
    case telephony_control_provider do
      "livekit" -> CommsIntegrations.Telephony.LiveKit
      "asterisk_ari" -> CommsIntegrations.Telephony.AsteriskARI
      _ -> raise "TELEPHONY_CONTROL_PROVIDER must be livekit or asterisk_ari"
    end

  telephony_transfer_enabled? =
    parse_boolean.(
      System.get_env("TELEPHONY_TRANSFER_ENABLED", "false"),
      "TELEPHONY_TRANSFER_ENABLED"
    )

  telephony_transfer_prefixes = csv_values.("TELEPHONY_TRANSFER_DESTINATION_PREFIXES")
  telephony_pbx_prefixes = csv_values.("TELEPHONY_PBX_DESTINATION_PREFIXES")

  for {name, prefixes} <- [
        {"TELEPHONY_TRANSFER_DESTINATION_PREFIXES", telephony_transfer_prefixes},
        {"TELEPHONY_PBX_DESTINATION_PREFIXES", telephony_pbx_prefixes}
      ] do
    unless Enum.all?(prefixes, &Regex.match?(~r/^\+[1-9][0-9]{0,14}$/, &1)),
      do: raise("#{name} must contain explicit international phone prefixes")
  end

  if telephony_transfer_enabled? and
       (telephony_provider_mode != "livekit" or telephony_transfer_prefixes == []),
     do:
       raise(
         "TELEPHONY_TRANSFER_ENABLED requires LiveKit telephony and explicit destination prefixes"
       )

  telephony_pbx_enabled? =
    parse_boolean.(System.get_env("TELEPHONY_PBX_ENABLED", "false"), "TELEPHONY_PBX_ENABLED")

  telephony_pbx_qualified? =
    parse_boolean.(System.get_env("TELEPHONY_PBX_QUALIFIED", "false"), "TELEPHONY_PBX_QUALIFIED")

  telephony_pbx_origin = System.get_env("TELEPHONY_PBX_API_URL")
  telephony_pbx_username = optional_secret.("TELEPHONY_PBX_USERNAME")
  telephony_pbx_password = optional_secret.("TELEPHONY_PBX_PASSWORD")
  telephony_pbx_endpoint = System.get_env("TELEPHONY_PBX_ENDPOINT")
  telephony_pbx_application = System.get_env("TELEPHONY_PBX_APPLICATION", "k-comms")
  telephony_pbx_webhook_secret = optional_secret.("TELEPHONY_PBX_WEBHOOK_SECRET")

  if telephony_pbx_webhook_secret && byte_size(telephony_pbx_webhook_secret) < 32,
    do: raise("TELEPHONY_PBX_WEBHOOK_SECRET must contain at least 32 bytes")

  if telephony_pbx_enabled? or telephony_pbx_qualified? do
    unless telephony_control_provider == "asterisk_ari" and
             https_dns_url?.(telephony_pbx_origin, true) and
             is_binary(telephony_pbx_username) and byte_size(telephony_pbx_username) in 1..256 and
             is_binary(telephony_pbx_password) and byte_size(telephony_pbx_password) >= 24 and
             is_binary(telephony_pbx_endpoint) and
             Regex.match?(~r/^[A-Za-z0-9_-]{1,100}$/, telephony_pbx_endpoint) and
             Regex.match?(~r/^[A-Za-z0-9_-]{1,100}$/, telephony_pbx_application) do
      raise "TELEPHONY_PBX_ENABLED or QUALIFIED requires an explicit Asterisk ARI control provider and complete HTTPS PBX configuration"
    end
  end

  telephony_ivr_qualified? =
    parse_boolean.(System.get_env("TELEPHONY_IVR_QUALIFIED", "false"), "TELEPHONY_IVR_QUALIFIED")

  telephony_ivr_prompts = csv_values.("TELEPHONY_IVR_PROMPT_ALLOWLIST")

  unless length(telephony_ivr_prompts) <= 20 and
           Enum.all?(telephony_ivr_prompts, &Regex.match?(~r/^sound:[A-Za-z0-9_\/-]{1,150}$/, &1)) do
    raise "TELEPHONY_IVR_PROMPT_ALLOWLIST requires at most 20 reviewed sound media names"
  end

  if telephony_ivr_qualified? and
       not (telephony_pbx_enabled? and telephony_pbx_qualified? and telephony_ivr_prompts != [] and
              is_binary(telephony_pbx_webhook_secret) and
              byte_size(telephony_pbx_webhook_secret) >= 32) do
    raise "TELEPHONY_IVR_QUALIFIED requires qualified ARI, approved prompts and signed event relay"
  end

  voicemail_storage_qualified? =
    parse_boolean.(
      System.get_env("TELEPHONY_VOICEMAIL_STORAGE_QUALIFIED", "false"),
      "TELEPHONY_VOICEMAIL_STORAGE_QUALIFIED"
    )

  artifact_privacy_approved? =
    parse_boolean.(
      System.get_env("MEETING_ARTIFACT_PRIVACY_APPROVED", "false"),
      "MEETING_ARTIFACT_PRIVACY_APPROVED"
    )

  artifact_provider_qualified? =
    parse_boolean.(
      System.get_env("MEETING_ARTIFACT_PROVIDER_QUALIFIED", "false"),
      "MEETING_ARTIFACT_PROVIDER_QUALIFIED"
    )

  artifact_tenant_ids = csv_values.("MEETING_ARTIFACT_ENABLED_TENANT_IDS")

  unless Enum.all?(artifact_tenant_ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
    do: raise("MEETING_ARTIFACT_ENABLED_TENANT_IDS must contain tenant UUIDs")

  artifact_tenant_ids =
    Enum.map(artifact_tenant_ids, fn id ->
      {:ok, value} = Ecto.UUID.cast(id)
      value
    end)

  meeting_artifacts_enabled? =
    parse_boolean.(
      System.get_env("MEETING_ARTIFACTS_ENABLED", "false"),
      "MEETING_ARTIFACTS_ENABLED"
    )

  egress_enabled? =
    parse_boolean.(System.get_env("LIVEKIT_EGRESS_ENABLED", "false"), "LIVEKIT_EGRESS_ENABLED")

  unless meeting_artifacts_enabled? == egress_enabled?,
    do: raise("MEETING_ARTIFACTS_ENABLED and LIVEKIT_EGRESS_ENABLED must be enabled together")

  artifact_transcription_enabled? =
    parse_boolean.(
      System.get_env("ARTIFACT_TRANSCRIPTION_ENABLED", "false"),
      "ARTIFACT_TRANSCRIPTION_ENABLED"
    )

  artifact_transcription_qualified? =
    parse_boolean.(
      System.get_env("ARTIFACT_TRANSCRIPTION_QUALIFIED", "false"),
      "ARTIFACT_TRANSCRIPTION_QUALIFIED"
    )

  artifact_transcription_origin = System.get_env("ARTIFACT_TRANSCRIPTION_ORIGIN")
  artifact_transcription_model = System.get_env("ARTIFACT_TRANSCRIPTION_MODEL", "whisper-1")

  artifact_transcription_language =
    case System.get_env("ARTIFACT_TRANSCRIPTION_LANGUAGE") do
      nil -> nil
      "" -> nil
      value -> value
    end

  if meeting_artifacts_enabled? or artifact_transcription_enabled? do
    unless artifact_privacy_approved? and artifact_provider_qualified? and
             artifact_tenant_ids != [] and audio_provider_mode == "livekit",
           do:
             raise(
               "Meeting recording and transcription require privacy approval, qualified LiveKit and explicit tenant UUIDs"
             )

    if direct_audio_p2p_enabled?,
      do: raise("Meeting recording and transcription require DIRECT_AUDIO_P2P_ENABLED=false")
  end

  if artifact_transcription_enabled? and
       (not artifact_transcription_qualified? or
          not https_dns_url?.(artifact_transcription_origin, true)),
     do: raise("ARTIFACT_TRANSCRIPTION_ENABLED requires a qualified fixed HTTPS provider origin")

  unless Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/, artifact_transcription_model),
    do: raise("ARTIFACT_TRANSCRIPTION_MODEL is invalid")

  unless is_nil(artifact_transcription_language) or
           Regex.match?(~r/^[a-z]{2,3}$/, artifact_transcription_language),
         do: raise("ARTIFACT_TRANSCRIPTION_LANGUAGE must be a two or three letter language code")

  artifact_transcription = [
    enabled: artifact_transcription_enabled?,
    qualified: artifact_transcription_qualified?,
    origin: artifact_transcription_origin,
    max_media_bytes:
      parse_bounded_integer.(
        System.get_env("ARTIFACT_TRANSCRIPTION_MAX_MEDIA_BYTES", "26214400"),
        "ARTIFACT_TRANSCRIPTION_MAX_MEDIA_BYTES",
        1..26_214_400
      ),
    max_response_bytes:
      parse_bounded_integer.(
        System.get_env("ARTIFACT_TRANSCRIPTION_MAX_RESPONSE_BYTES", "1048576"),
        "ARTIFACT_TRANSCRIPTION_MAX_RESPONSE_BYTES",
        1..1_048_576
      ),
    timeout_ms:
      parse_bounded_integer.(
        System.get_env("ARTIFACT_TRANSCRIPTION_TIMEOUT_MS", "30000"),
        "ARTIFACT_TRANSCRIPTION_TIMEOUT_MS",
        1_000..60_000
      ),
    model: artifact_transcription_model,
    language: artifact_transcription_language
  ]

  oidc_enabled? = parse_boolean.(System.get_env("OIDC_ENABLED", "false"), "OIDC_ENABLED")
  oidc_issuer = System.get_env("OIDC_ISSUER")
  oidc_client_id = System.get_env("OIDC_CLIENT_ID")
  oidc_client_secret = optional_secret.("OIDC_CLIENT_SECRET")
  oidc_redirect_uri = System.get_env("OIDC_REDIRECT_URI")

  oidc_allowed_redirect_uris =
    parse_json_list.(
      System.get_env("OIDC_ALLOWED_REDIRECT_URIS_JSON"),
      "OIDC_ALLOWED_REDIRECT_URIS_JSON"
    )

  oidc_acr_values = csv_values.("OIDC_REQUIRED_ACR_VALUES")

  oidc_scim_subject_mapping? =
    parse_boolean.(
      System.get_env("OIDC_SCIM_SUBJECT_MAPPING", "false"),
      "OIDC_SCIM_SUBJECT_MAPPING"
    )

  if oidc_enabled? do
    unless https_dns_url?.(oidc_issuer, false) and https_dns_url?.(oidc_redirect_uri, false) and
             is_binary(oidc_client_id) and byte_size(oidc_client_id) in 1..512 and
             is_binary(oidc_client_secret) and byte_size(oidc_client_secret) >= 16 and
             oidc_redirect_uri in oidc_allowed_redirect_uris and
             Enum.all?(oidc_allowed_redirect_uris, &https_dns_url?.(&1, false)) and
             length(oidc_acr_values) in 1..10 and
             Enum.all?(oidc_acr_values, &(byte_size(&1) in 1..256)) do
      raise "OIDC_ENABLED requires complete HTTPS identity configuration, approved redirects and required assurance values"
    end
  end

  if oidc_scim_subject_mapping? and not oidc_enabled?,
    do: raise("OIDC_SCIM_SUBJECT_MAPPING requires enabled OIDC")

  oidc_config = %{
    enabled: oidc_enabled?,
    issuer: oidc_issuer,
    client_id: oidc_client_id,
    client_secret: oidc_client_secret,
    redirect_uri: oidc_redirect_uri,
    allowed_redirect_uris: oidc_allowed_redirect_uris,
    required_acr_values: oidc_acr_values,
    scim_subject_mapping: oidc_scim_subject_mapping?
  }

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

  calendar_keys_encoded = optional_secret.("CALENDAR_SECRET_ENCRYPTION_KEYS")
  calendar_current_key_id = System.get_env("CALENDAR_ENCRYPTION_KEY_ID", "primary")

  if calendar_keys_encoded do
    entries = String.split(calendar_keys_encoded, ",", trim: false)

    unless length(entries) in 1..8 and
             Enum.all?(entries, fn entry ->
               case String.split(entry, ":", parts: 2) do
                 [id, encoded] ->
                   Regex.match?(~r/\A[A-Za-z0-9_.-]{1,64}\z/, id) and
                     Regex.match?(~r/\A[A-Za-z0-9+\/]{43}=\z/, encoded)

                 _ ->
                   false
               end
             end),
           do: raise("Calendar keyring must contain 1 to 8 exact key_id:Base64 entries")
  end

  calendar_keys = parse_keyring.(calendar_keys_encoded, "CALENDAR_SECRET_ENCRYPTION_KEYS")

  unless Regex.match?(~r/\A[A-Za-z0-9_.-]{1,64}\z/, calendar_current_key_id) and
           (is_nil(calendar_keys) or Map.has_key?(calendar_keys, calendar_current_key_id)),
         do: raise("Calendar active key identifier must select a configured key")

  calendar_origin = URI.to_string(%URI{public_app_uri | path: nil, query: nil, fragment: nil})

  calendar_providers =
    Map.new([:google, :microsoft], fn provider ->
      prefix = "CALENDAR_" <> (provider |> Atom.to_string() |> String.upcase())

      enabled =
        parse_boolean.(System.get_env(prefix <> "_ENABLED", "false"), prefix <> "_ENABLED")

      client_id = System.get_env(prefix <> "_CLIENT_ID")
      client_secret = optional_secret.(prefix <> "_CLIENT_SECRET")
      tenant_id = System.get_env(prefix <> "_TENANT_ID")

      if enabled do
        unless is_map(calendar_keys) and public_app_uri.scheme == "https" and
                 public_app_uri.port == 443 and
                 is_binary(client_id) and byte_size(client_id) in 1..512 and
                 Regex.match?(~r/\A[\x21-\x7e]+\z/, client_id) and
                 is_binary(client_secret) and byte_size(client_secret) in 16..4096 and
                 Regex.match?(~r/\A[\x21-\x7e]+\z/, client_secret) and
                 (provider == :google or
                    (is_binary(tenant_id) and
                       Regex.match?(
                         ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
                         tenant_id
                       ))),
               do:
                 raise(
                   "Enabled Calendar providers require dedicated keys and bounded HTTPS OAuth configuration"
                 )
      end

      {provider,
       %{
         enabled: enabled,
         client_id: client_id,
         client_secret: client_secret,
         tenant_id: tenant_id,
         workspace_origin: calendar_origin,
         redirect_uri:
           calendar_origin <>
             "/api/v1/calendar/oauth/" <>
             Atom.to_string(provider) <> "/callback"
       }}
    end)

  config :comms_integrations, calendar_providers: calendar_providers

  config :comms_core,
    calendar_workspace_origin: calendar_origin,
    calendar_secret_keyring: %{current_key_id: calendar_current_key_id, keys: calendar_keys}

  governance_history_cursor_key =
    case System.get_env("GOV_HISTORY_CURSOR_KEY") do
      value when value in [nil, ""] -> nil
      value when byte_size(value) >= 32 -> value
      _ -> raise "GOV_HISTORY_CURSOR_KEY must contain at least 32 bytes when configured"
    end

  if governance_history_cursor_key do
    materials = fn value ->
      case Base.decode64(value) do
        {:ok, decoded} when byte_size(decoded) == 32 -> [value, decoded]
        _ -> [value]
      end
    end

    history_materials = materials.(governance_history_cursor_key)

    reused? =
      System.get_env()
      |> Enum.reject(fn {name, _value} -> name == "GOV_HISTORY_CURSOR_KEY" end)
      |> Enum.filter(fn {name, _value} ->
        name == "RELEASE_COOKIE" or
          Regex.match?(~r/(SECRET|PASSWORD|TOKEN|SIGNING_KEY|ENCRYPTION_KEYS?)(?:$|_)/, name)
      end)
      |> Enum.flat_map(fn {name, value} ->
        cond do
          String.ends_with?(name, "_KEYS_JSON") ->
            case Jason.decode(value) do
              {:ok, keys} when is_map(keys) -> Enum.filter(Map.values(keys), &is_binary/1)
              _ -> [value]
            end

          String.ends_with?(name, "_KEYS") ->
            [
              value
              | Enum.map(String.split(value, ","), &List.last(String.split(&1, ":", parts: 2)))
            ]

          true ->
            [value]
        end
      end)
      |> Enum.flat_map(materials)
      |> Enum.any?(&(&1 in history_materials))

    if reused?, do: raise("GOV_HISTORY_CURSOR_KEY must use dedicated secret material")
  end

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

  identity_secret_encryption_key = optional_secret.("IDENTITY_SECRET_ENCRYPTION_KEY")

  identity_secret_encryption_key_id =
    System.get_env("IDENTITY_SECRET_ENCRYPTION_KEY_ID", "primary")

  identity_keys_csv = optional_secret.("IDENTITY_SECRET_ENCRYPTION_KEYS")
  identity_keys_json = optional_secret.("IDENTITY_SECRET_ENCRYPTION_KEYS_JSON")

  if identity_keys_csv && identity_keys_json,
    do: raise("IDENTITY_SECRET_ENCRYPTION_KEYS and KEYS_JSON are mutually exclusive")

  identity_secret_encryption_keys =
    if identity_keys_json do
      case Jason.decode(identity_keys_json, objects: :ordered_objects) do
        {:ok, %Jason.OrderedObject{values: entries}} when length(entries) in 1..20 ->
          unless Enum.all?(entries, fn {id, value} -> is_binary(id) and is_binary(value) end),
            do:
              raise(
                "IDENTITY_SECRET_ENCRYPTION_KEYS_JSON must map key identifiers to Base64 keys"
              )

          encoded = Enum.map_join(entries, ",", fn {id, value} -> id <> ":" <> value end)
          parse_keyring.(encoded, "IDENTITY_SECRET_ENCRYPTION_KEYS_JSON")

        _ ->
          raise "IDENTITY_SECRET_ENCRYPTION_KEYS_JSON must contain a bounded key object"
      end
    else
      parse_keyring.(identity_keys_csv, "IDENTITY_SECRET_ENCRYPTION_KEYS")
    end

  if identity_secret_encryption_key_id == "legacy" or
       (is_map(identity_secret_encryption_keys) and
          Map.has_key?(identity_secret_encryption_keys, "legacy")),
     do: raise("Identity encryption must not use the reserved legacy key identifier")

  identity_break_glass_secret = optional_secret.("IDENTITY_BREAK_GLASS_SECRET")

  if identity_break_glass_secret && byte_size(identity_break_glass_secret) < 32,
    do: raise("IDENTITY_BREAK_GLASS_SECRET must contain at least 32 bytes")

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
        },
        {"IDENTITY_SECRET_ENCRYPTION_KEYS", identity_secret_encryption_key_id,
         identity_secret_encryption_keys}
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

  identity_materials =
    encryption_materials.(
      identity_secret_encryption_key,
      "IDENTITY_SECRET_ENCRYPTION_KEY",
      identity_secret_encryption_keys
    )

  shared_secret_materials =
    Enum.reduce(
      [
        secret_key_base,
        recovery_signing_key,
        identity_break_glass_secret,
        oidc_client_secret,
        telephony_pbx_password,
        telephony_pbx_webhook_secret,
        livekit_api_secret,
        turn_static_auth_secret
      ],
      MapSet.new(),
      fn
        value, set when is_binary(value) ->
          set = MapSet.put(set, value)

          case Base.decode64(value) do
            {:ok, decoded} -> MapSet.put(set, decoded)
            _ -> set
          end

        _, set ->
          set
      end
    )

  calendar_materials =
    encryption_materials.(nil, "CALENDAR_SECRET_ENCRYPTION_KEYS", calendar_keys)

  other_calendar_materials =
    Enum.reduce(
      [identity_materials, webhook_materials, push_materials],
      shared_secret_materials,
      &MapSet.union/2
    )

  other_calendar_materials =
    Enum.reduce(Map.values(calendar_providers), other_calendar_materials, fn provider, set ->
      if is_binary(provider.client_secret) do
        set = MapSet.put(set, provider.client_secret)

        case Base.decode64(provider.client_secret) do
          {:ok, decoded} -> MapSet.put(set, decoded)
          _ -> set
        end
      else
        set
      end
    end)

  other_calendar_materials =
    if governance_history_cursor_key do
      set = MapSet.put(other_calendar_materials, governance_history_cursor_key)

      case Base.decode64(governance_history_cursor_key) do
        {:ok, decoded} -> MapSet.put(set, decoded)
        _ -> set
      end
    else
      other_calendar_materials
    end

  unless MapSet.disjoint?(calendar_materials, other_calendar_materials),
    do: raise("Calendar encryption must use dedicated secret material")

  shared_secret_materials =
    Enum.reduce(Map.values(calendar_providers), shared_secret_materials, fn provider, set ->
      if is_binary(provider.client_secret) do
        set = MapSet.put(set, provider.client_secret)

        case Base.decode64(provider.client_secret) do
          {:ok, decoded} -> MapSet.put(set, decoded)
          _ -> set
        end
      else
        set
      end
    end)

  # File-backed credentials are resolved after the environment-only check.
  # Compare actual decoded keyrings and provider secrets too; file paths cannot
  # establish that their loaded material is independent from history signing.
  if governance_history_cursor_key do
    history_materials =
      case Base.decode64(governance_history_cursor_key) do
        {:ok, decoded} -> MapSet.new([governance_history_cursor_key, decoded])
        _ -> MapSet.new([governance_history_cursor_key])
      end

    other_materials =
      Enum.reduce(
        [identity_materials, webhook_materials, push_materials, calendar_materials],
        shared_secret_materials,
        &MapSet.union/2
      )

    unless MapSet.disjoint?(history_materials, other_materials),
      do: raise("GOV_HISTORY_CURSOR_KEY must use dedicated secret material")
  end

  for {name, materials} <- [
        {"identity", identity_materials},
        {"webhook", webhook_materials},
        {"push", push_materials}
      ] do
    unless MapSet.disjoint?(materials, shared_secret_materials),
      do:
        raise(
          "#{name} encryption keys must be independent from signing, recovery, provider and break-glass credentials"
        )
  end

  unless MapSet.disjoint?(identity_materials, webhook_materials) and
           MapSet.disjoint?(identity_materials, push_materials),
         do:
           raise(
             "Identity encryption key material must not be reused across webhook or push domains"
           )

  if oidc_enabled? and MapSet.size(identity_materials) == 0,
    do: raise("OIDC_ENABLED requires a dedicated identity encryption key")

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
    telephony_control_adapter: telephony_control_adapter,
    telephony_ivr_prompt_allowlist: telephony_ivr_prompts,
    telephony_control_fingerprint_key:
      :crypto.mac(:hmac, :sha256, secret_key_base, "k-comms-telephony-controls-v1"),
    direct_audio_p2p_enabled: direct_audio_p2p_enabled?,
    meeting_artifact_policy: [
      privacy_approved: artifact_privacy_approved?,
      provider_qualified: artifact_provider_qualified?,
      enabled_tenant_ids: artifact_tenant_ids
    ],
    identity_secret_encryption_key: identity_secret_encryption_key,
    identity_secret_encryption_key_id: identity_secret_encryption_key_id,
    identity_secret_encryption_keys: identity_secret_encryption_keys,
    identity_break_glass_secret: identity_break_glass_secret,
    oidc: oidc_config,
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
    governance_history_cursor_key: governance_history_cursor_key,
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
    direct_audio_p2p_enabled: direct_audio_p2p_enabled?,
    immersive_mode_enabled: immersive_mode_enabled?,
    direct_audio_stun_urls: direct_audio_stun_urls,
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
    http: [
      ip: {0, 0, 0, 0},
      port: port,
      websocket_options: [
        max_frame_size: 1_048_576,
        max_fragmented_message_size: 1_048_576
      ]
    ],
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

  config :comms_core,
    telephony_ring_timeout_seconds: telephony_ring_timeout_seconds,
    telephony_max_duration_seconds: telephony_max_duration_seconds

  config :comms_integrations,
    audio_provider_mode: audio_provider_mode,
    telephony_provider_mode: telephony_provider_mode,
    telephony_transfer_enabled: telephony_transfer_enabled?,
    telephony_transfer_destination_prefixes: telephony_transfer_prefixes,
    telephony_pbx_enabled: telephony_pbx_enabled?,
    telephony_pbx_qualified: telephony_pbx_qualified?,
    telephony_ivr_qualified: telephony_ivr_qualified?,
    telephony_ivr_prompt_allowlist: telephony_ivr_prompts,
    telephony_pbx_api_url: telephony_pbx_origin,
    telephony_pbx_username: telephony_pbx_username,
    telephony_pbx_password: telephony_pbx_password,
    telephony_pbx_endpoint: telephony_pbx_endpoint,
    telephony_pbx_application: telephony_pbx_application,
    telephony_pbx_destination_prefixes: telephony_pbx_prefixes,
    telephony_pbx_webhook_secret: telephony_pbx_webhook_secret,
    telephony_voicemail_storage_qualified: voicemail_storage_qualified?,
    meeting_artifacts_enabled: meeting_artifacts_enabled?,
    egress_enabled: egress_enabled?,
    artifact_transcription: artifact_transcription,
    telephony_ring_timeout_seconds: telephony_ring_timeout_seconds,
    telephony_max_duration_seconds: telephony_max_duration_seconds,
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
