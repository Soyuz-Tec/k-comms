defmodule CommsIntegrations.MeetingArtifacts.Config do
  @moduledoc false

  alias CommsIntegrations.ObjectStorage.S3.EndpointPolicy

  def configuration do
    if Application.get_env(:comms_integrations, :meeting_artifacts_enabled, false) == true and
         Application.get_env(:comms_integrations, :egress_enabled, false) == true do
      control_configuration()
    else
      {:error, :artifact_provider_unavailable}
    end
  end

  # Admission flags must not strand an existing recording after consent is revoked.
  def control_configuration do
    api_url = Application.get_env(:comms_integrations, :livekit_api_url)
    api_key = Application.get_env(:comms_integrations, :livekit_api_key)
    api_secret = Application.get_env(:comms_integrations, :livekit_api_secret)

    with true <-
           Application.get_env(:comms_integrations, :audio_provider_mode) in [:livekit, "livekit"],
         true <- valid_api_origin?(api_url),
         true <- valid_secret?(api_key, 8) and valid_secret?(api_secret, 32),
         {:ok, storage} <- storage_configuration() do
      {:ok, %{api_url: api_url, api_key: api_key, api_secret: api_secret, storage: storage}}
    else
      _ -> {:error, :artifact_provider_unavailable}
    end
  end

  def storage_configuration do
    storage = Application.get_env(:comms_integrations, :s3, [])

    with true <- Keyword.keyword?(storage),
         true <-
           Application.get_env(:comms_integrations, :object_storage_adapter) ==
             CommsIntegrations.ObjectStorage.S3,
         %{status: :available} <- EndpointPolicy.status(storage),
         true <- valid_bucket?(Keyword.get(storage, :bucket)),
         true <- valid_storage_origin?(storage, :public),
         true <- valid_storage_origin?(storage, :internal),
         true <- valid_region?(Keyword.get(storage, :region)),
         true <- valid_secret?(Keyword.get(storage, :access_key_id), 1),
         true <- valid_secret?(Keyword.get(storage, :secret_access_key), 1) do
      {:ok, storage}
    else
      _ -> {:error, :artifact_storage_unavailable}
    end
  end

  def storage_output(storage) do
    scheme = Keyword.fetch!(storage, :scheme)
    host = Keyword.fetch!(storage, :host)
    port = Keyword.fetch!(storage, :port)
    uri = %URI{scheme: scheme, host: host, port: port}

    %{
      access_key: Keyword.fetch!(storage, :access_key_id),
      secret: Keyword.fetch!(storage, :secret_access_key),
      region: Keyword.fetch!(storage, :region),
      bucket: Keyword.fetch!(storage, :bucket),
      endpoint: URI.to_string(uri),
      force_path_style: true
    }
  end

  defp valid_api_origin?(value) when is_binary(value) do
    uri = URI.parse(value)

    local? =
      Application.get_env(:comms_integrations, :allow_insecure_local_media, false) == true and
        uri.host in ["localhost", "127.0.0.1", "::1"]

    uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and
      is_nil(uri.fragment) and is_binary(uri.host) and uri.host != "" and
      not String.ends_with?(String.downcase(uri.host), ".invalid") and
      ((uri.scheme == "https" and uri.port == 443 and
          match?({:error, _}, :inet.parse_address(String.to_charlist(uri.host)))) or
         (local? and uri.scheme == "http"))
  rescue
    ArgumentError -> false
  end

  defp valid_api_origin?(_), do: false

  defp valid_secret?(value, minimum) when is_binary(value),
    do:
      byte_size(String.trim(value)) >= minimum and
        not Regex.match?(~r/(?:CHANGE_ME|REPLACE_WITH)/i, value)

  defp valid_secret?(_, _), do: false

  defp valid_bucket?(value) when is_binary(value),
    do: Regex.match?(~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/, value)

  defp valid_bucket?(_), do: false

  defp valid_storage_origin?(storage, purpose) do
    host = endpoint_value(storage, purpose, :host)
    port = endpoint_value(storage, purpose, :port)

    is_binary(host) and is_integer(port) and port in 1..65_535 and
      (match?({:ok, _}, :inet.parse_address(String.to_charlist(host))) or
         Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/, host))
  end

  defp endpoint_value(storage, :public, key), do: Keyword.get(storage, key)

  defp endpoint_value(storage, :internal, key) do
    internal_key = %{host: :internal_host, port: :internal_port}
    Keyword.get(storage, Map.fetch!(internal_key, key), Keyword.get(storage, key))
  end

  defp valid_region?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/, value)
end
