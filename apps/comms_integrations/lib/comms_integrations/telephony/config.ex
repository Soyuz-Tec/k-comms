defmodule CommsIntegrations.Telephony.Config do
  @moduledoc false

  def validate!(options) do
    case configuration(options) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid telephony configuration: #{reason}"
    end
  end

  # Turning off new telephony admissions must not strand existing SIP legs.
  # Read-only reconciliation and exact-room cleanup retain the separately
  # configured media control credentials without enabling new dialing.
  def control_configuration do
    application_options() |> Keyword.put(:mode, "livekit") |> configuration()
  end

  def configuration(options \\ application_options()) do
    mode = Keyword.get(options, :mode, "disabled")

    cond do
      mode in ["disabled", :disabled] ->
        {:ok, %{enabled: false}}

      mode not in ["livekit", :livekit] ->
        {:error, :telephony_provider_mode}

      Keyword.get(options, :audio_mode) not in ["livekit", :livekit] ->
        {:error, :audio_provider_mode}

      not valid_origin?(Keyword.get(options, :server_url), :signalling, options) ->
        {:error, :livekit_server_url}

      not valid_origin?(Keyword.get(options, :api_url), :api, options) ->
        {:error, :livekit_api_url}

      not valid_secret?(Keyword.get(options, :api_key), 8) ->
        {:error, :livekit_api_key}

      not valid_secret?(Keyword.get(options, :api_secret), 32) ->
        {:error, :livekit_api_secret}

      Keyword.get(options, :ring_timeout_seconds, 45) not in 10..90 ->
        {:error, :telephony_ring_timeout_seconds}

      Keyword.get(options, :max_duration_seconds, 1_800) not in 60..14_400 ->
        {:error, :telephony_max_duration_seconds}

      true ->
        {:ok,
         %{
           enabled: true,
           server_url: Keyword.fetch!(options, :server_url),
           api_url: Keyword.fetch!(options, :api_url),
           api_key: Keyword.fetch!(options, :api_key),
           api_secret: Keyword.fetch!(options, :api_secret),
           ring_timeout_seconds: Keyword.get(options, :ring_timeout_seconds, 45),
           max_duration_seconds: Keyword.get(options, :max_duration_seconds, 1_800)
         }}
    end
  end

  defp application_options do
    [
      mode: Application.get_env(:comms_integrations, :telephony_provider_mode, "disabled"),
      audio_mode: Application.get_env(:comms_integrations, :audio_provider_mode, "disabled"),
      server_url: Application.get_env(:comms_integrations, :livekit_server_url),
      api_url: Application.get_env(:comms_integrations, :livekit_api_url),
      api_key: Application.get_env(:comms_integrations, :livekit_api_key),
      api_secret: Application.get_env(:comms_integrations, :livekit_api_secret),
      ring_timeout_seconds:
        Application.get_env(:comms_integrations, :telephony_ring_timeout_seconds, 45),
      max_duration_seconds:
        Application.get_env(:comms_integrations, :telephony_max_duration_seconds, 1_800),
      allow_insecure_local_media:
        Application.get_env(:comms_integrations, :allow_insecure_local_media, false)
    ]
  end

  defp valid_origin?(value, kind, options) when is_binary(value) do
    uri = URI.parse(value)
    secure_scheme = if kind == :api, do: "https", else: "wss"
    local_scheme = if kind == :api, do: "http", else: "ws"

    local? =
      Keyword.get(options, :allow_insecure_local_media) == true and
        uri.host in ["localhost", "127.0.0.1", "::1"]

    origin? =
      is_binary(uri.host) and String.trim(uri.host) != "" and
        not String.ends_with?(String.downcase(uri.host), ".invalid") and
        uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and
        is_nil(uri.query) and is_nil(uri.fragment)

    origin? and
      ((uri.scheme == secure_scheme and uri.port == 443 and dns_host?(uri.host)) or
         (local? and uri.scheme == local_scheme))
  rescue
    ArgumentError -> false
  end

  defp valid_origin?(_, _, _), do: false

  defp dns_host?(host) do
    match?({:error, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp valid_secret?(value, minimum) when is_binary(value) do
    byte_size(String.trim(value)) >= minimum and
      not Regex.match?(~r/(?:CHANGE_ME|REPLACE_WITH)/i, value)
  end

  defp valid_secret?(_, _), do: false
end
