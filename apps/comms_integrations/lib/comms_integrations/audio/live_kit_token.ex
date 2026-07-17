defmodule CommsIntegrations.Audio.LiveKitToken do
  @moduledoc "Issues short-lived LiveKit credentials for audio and video conversation calls."

  @minimum_ttl_seconds 60
  @maximum_ttl_seconds 300

  def issue(call, participant, user) when is_map(call) and is_map(participant) and is_map(user) do
    with {:ok, config} <- configuration(),
         {:ok, room} <- required_binary(call, :provider_room),
         {:ok, media_kind} <- media_kind(call),
         {:ok, identity} <- required_binary(participant, :provider_identity),
         {:ok, display_name} <- required_binary(user, :display_name) do
      now = System.system_time(:second)

      claims = %{
        "exp" => now + config.ttl_seconds,
        "iss" => config.api_key,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "name" => display_name,
        "nbf" => now - 5,
        "sub" => identity,
        "video" => %{
          "canPublish" => true,
          "canPublishData" => false,
          "canPublishSources" => publish_sources(media_kind),
          "canSubscribe" => true,
          "canUpdateOwnMetadata" => false,
          "room" => room,
          "roomAdmin" => false,
          "roomJoin" => true,
          "roomRecord" => false
        }
      }

      {:ok,
       %{
         server_url: config.server_url,
         participant_token: sign(claims, config.api_secret),
         expires_in: config.ttl_seconds
       }}
    else
      {:error, :audio_identity_invalid} = error -> error
      _ -> {:error, :audio_provider_unavailable}
    end
  end

  def issue(_, _, _), do: {:error, :audio_identity_invalid}

  def issue_room_control(call) when is_map(call) do
    with {:ok, config} <- configuration(),
         {:ok, room} <- required_binary(call, :provider_room) do
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

  def issue_room_admin(call) when is_map(call) do
    with {:ok, config} <- configuration(),
         {:ok, room} <- required_binary(call, :provider_room) do
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

  def ensure_available do
    case configuration() do
      {:ok, _config} -> :ok
      {:error, _reason} -> {:error, :audio_provider_unavailable}
    end
  end

  def status do
    case configuration() do
      {:ok, config} ->
        %{status: :available, adapter: :livekit, server_url: config.server_url}

      {:error, reason} ->
        %{status: :unavailable, adapter: :disabled, reason: reason}
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

  defp required_binary(map, key) do
    case value(map, key) do
      text when is_binary(text) ->
        if configured?(text), do: {:ok, text}, else: {:error, :audio_identity_invalid}

      _ ->
        {:error, :audio_identity_invalid}
    end
  end

  defp media_kind(call) do
    case value(call, :media_kind) || :audio do
      media_kind when media_kind in [:audio, "audio"] -> {:ok, :audio}
      media_kind when media_kind in [:video, "video"] -> {:ok, :video}
      _ -> {:error, :audio_identity_invalid}
    end
  end

  defp publish_sources(:audio), do: ["microphone"]

  defp publish_sources(:video),
    do: ["microphone", "camera", "screen_share", "screen_share_audio"]

  defp valid_server_url?(value) when is_binary(value) do
    uri = URI.parse(value)

    uri.scheme in ["ws", "wss"] and configured?(uri.host) and uri.path in [nil, "", "/"] and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_server_url?(_), do: false

  defp valid_api_url?(value) when is_binary(value) do
    uri = URI.parse(value)

    uri.scheme in ["http", "https"] and configured?(uri.host) and uri.path in [nil, "", "/"] and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_api_url?(_), do: false
  defp configured?(value), do: is_binary(value) and String.trim(value) != ""
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
