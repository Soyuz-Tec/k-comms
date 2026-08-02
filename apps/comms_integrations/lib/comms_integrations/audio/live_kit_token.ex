defmodule CommsIntegrations.Audio.LiveKitToken do
  @moduledoc "Issues short-lived LiveKit credentials for audio and video conversation calls."

  alias CommsIntegrations.Audio.IceServers

  @minimum_ttl_seconds 60
  @maximum_ttl_seconds 300

  def issue(
        provider_room,
        media_kind,
        provider_identity,
        display_name,
        authorization_expires_at \\ nil
      ),
      do:
        issue(
          provider_room,
          media_kind,
          provider_identity,
          display_name,
          authorization_expires_at,
          %{}
        )

  def issue(
        provider_room,
        media_kind,
        provider_identity,
        display_name,
        authorization_expires_at,
        metadata
      )
      when is_binary(provider_room) and media_kind in [:audio, :video, "audio", "video"] and
             is_binary(provider_identity) and is_binary(display_name) and is_map(metadata) do
    now = System.system_time(:second)

    with {:ok, config} <- configuration(),
         {:ok, room} <- required_binary(provider_room),
         {:ok, normalized_media_kind} <- media_kind(media_kind),
         {:ok, identity} <- required_binary(provider_identity),
         {:ok, name} <- required_binary(display_name),
         {:ok, expires_in} <-
           effective_ttl(config.ttl_seconds, authorization_expires_at, now),
         # A configured-but-invalid relay fails the credential rather than
         # silently issuing one without it: a silent fallback would drop
         # restricted-network participants back to the failure this prevents.
         {:ok, ice_servers} <- IceServers.for_participant(identity) do
      claims = %{
        "exp" => now + expires_in,
        "iss" => config.api_key,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "name" => name,
        "nbf" => now - 5,
        "sub" => identity,
        "video" => %{
          "canPublish" => true,
          "canPublishData" => false,
          "canPublishSources" => publish_sources(normalized_media_kind),
          "canSubscribe" => true,
          "canUpdateOwnMetadata" => false,
          "room" => room,
          "roomAdmin" => false,
          "roomJoin" => true,
          "roomRecord" => false
        }
      }

      claims =
        if map_size(metadata) > 0,
          do: Map.put(claims, "metadata", Jason.encode!(metadata)),
          else: claims

      {:ok,
       %{
         server_url: config.server_url,
         participant_token: sign(claims, config.api_secret),
         expires_in: expires_in,
         ice_servers: ice_servers
       }}
    else
      {:error, reason} = error
      when reason in [:audio_identity_invalid, :call_authorization_expired] ->
        error

      _ ->
        {:error, :audio_provider_unavailable}
    end
  end

  def issue(_, _, _, _, _, _), do: {:error, :audio_identity_invalid}

  def issue_room_control(provider_room) when is_binary(provider_room) do
    with {:ok, config} <- configuration(),
         {:ok, room} <- required_binary(provider_room) do
      now = System.system_time(:second)

      claims = %{
        "exp" => now + 30,
        "iss" => config.api_key,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "nbf" => now - 5,
        "video" => %{"roomCreate" => true}
      }

      {:ok,
       %{
         api_url: config.api_url,
         room: room,
         token: sign(claims, config.api_secret)
       }}
    else
      _ -> {:error, :audio_provider_unavailable}
    end
  end

  def issue_room_control(_), do: {:error, :audio_provider_unavailable}

  def issue_room_admin(provider_room) when is_binary(provider_room) do
    with {:ok, config} <- configuration(),
         {:ok, room} <- required_binary(provider_room) do
      now = System.system_time(:second)

      claims = %{
        "exp" => now + 30,
        "iss" => config.api_key,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "nbf" => now - 5,
        "video" => %{"room" => room, "roomAdmin" => true}
      }

      {:ok,
       %{
         api_url: config.api_url,
         room: room,
         token: sign(claims, config.api_secret)
       }}
    else
      _ -> {:error, :audio_provider_unavailable}
    end
  end

  def issue_room_admin(_), do: {:error, :audio_provider_unavailable}

  @doc false
  def issue_readiness do
    with {:ok, config} <- configuration() do
      now = System.system_time(:second)

      claims = %{
        "exp" => now + 30,
        "iss" => config.api_key,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "nbf" => now - 5,
        "video" => %{"roomList" => true}
      }

      {:ok,
       %{
         api_url: config.api_url,
         token: sign(claims, config.api_secret)
       }}
    else
      _ -> {:error, :audio_provider_unavailable}
    end
  end

  def ensure_available do
    case configuration() do
      {:ok, _config} -> :ok
      {:error, _reason} -> {:error, :audio_provider_unavailable}
    end
  end

  defp configuration do
    mode = Application.get_env(:comms_integrations, :audio_provider_mode, "disabled")
    server_url = Application.get_env(:comms_integrations, :livekit_server_url)
    api_url = Application.get_env(:comms_integrations, :livekit_api_url)
    api_key = Application.get_env(:comms_integrations, :livekit_api_key)
    api_secret = Application.get_env(:comms_integrations, :livekit_api_secret)
    ttl_seconds = Application.get_env(:comms_integrations, :audio_token_ttl_seconds, 300)

    with true <- mode in ["livekit", :livekit],
         true <- valid_server_url?(server_url),
         true <- valid_api_url?(api_url),
         true <- configured?(api_key),
         true <- configured?(api_secret),
         true <-
           is_integer(ttl_seconds) and
             ttl_seconds >= @minimum_ttl_seconds and ttl_seconds <= @maximum_ttl_seconds do
      {:ok,
       %{
         server_url: server_url,
         api_url: api_url,
         api_key: api_key,
         api_secret: api_secret,
         ttl_seconds: ttl_seconds
       }}
    else
      _ -> {:error, :configuration_incomplete}
    end
  end

  defp sign(claims, secret) do
    header = encode_segment(%{"alg" => "HS256", "typ" => "JWT"})
    payload = encode_segment(claims)
    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)
    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode_segment(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp required_binary(text) when is_binary(text) do
    if configured?(text), do: {:ok, text}, else: {:error, :audio_identity_invalid}
  end

  defp media_kind(media_kind) do
    case media_kind do
      media_kind when media_kind in [:audio, "audio"] -> {:ok, :audio}
      media_kind when media_kind in [:video, "video"] -> {:ok, :video}
      _ -> {:error, :audio_identity_invalid}
    end
  end

  defp effective_ttl(configured_ttl, nil, _now), do: {:ok, configured_ttl}

  defp effective_ttl(configured_ttl, %DateTime{} = authorization_expires_at, now) do
    remaining = DateTime.to_unix(authorization_expires_at, :second) - now

    if remaining > 0 do
      {:ok, min(configured_ttl, remaining)}
    else
      {:error, :call_authorization_expired}
    end
  end

  defp effective_ttl(_configured_ttl, _authorization_expires_at, _now),
    do: {:error, :call_authorization_expired}

  defp publish_sources(:audio), do: ["microphone"]

  defp publish_sources(:video),
    do: ["microphone", "camera", "screen_share", "screen_share_audio"]

  defp valid_server_url?(value) when is_binary(value) do
    valid_endpoint?(value, signalling_schemes())
  end

  defp valid_server_url?(_), do: false

  defp valid_api_url?(value) when is_binary(value) do
    valid_endpoint?(value, api_schemes())
  end

  defp valid_api_url?(_), do: false

  defp valid_endpoint?(value, permitted_schemes) do
    uri = URI.parse(value)

    uri.scheme in permitted_schemes and configured?(uri.host) and uri.path in [nil, "", "/"] and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  # A participant token carries the signalling URL the browser will connect to,
  # and the room-control tokens are admin-scoped. Neither may travel over a
  # plaintext origin unless the explicit local-development gate is on, so
  # issuing fails closed rather than downgrading the transport.
  defp signalling_schemes do
    if allow_insecure_local_media?(), do: ["wss", "ws"], else: ["wss"]
  end

  defp api_schemes do
    if allow_insecure_local_media?(), do: ["https", "http"], else: ["https"]
  end

  defp allow_insecure_local_media? do
    Application.get_env(:comms_integrations, :allow_insecure_local_media, false) == true
  end

  defp configured?(value), do: is_binary(value) and String.trim(value) != ""
end
