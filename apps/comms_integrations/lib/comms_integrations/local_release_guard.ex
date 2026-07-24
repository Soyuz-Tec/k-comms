defmodule CommsIntegrations.LocalReleaseGuard do
  @moduledoc """
  Fail-closed validation for the packaged, loopback-only qualification runtime.

  This guard does not weaken the production provider contract. It permits
  clear-text HTTP and WebSocket origins only when an operator explicitly
  enables both the local-release gate and the existing development-adapter
  gate, and only for the fixed local Compose topology.
  """

  @loopback_hosts ["127.0.0.1", "::1", "localhost"]

  @spec validate!(keyword()) :: :ok
  def validate!(options) do
    if Keyword.fetch!(options, :enabled?) do
      validate_enabled!(options)
    end

    :ok
  end

  defp validate_enabled!(options) do
    unless Keyword.fetch!(options, :development_adapters?) do
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE=true requires ALLOW_DEVELOPMENT_ADAPTERS=true"
    end

    unless Keyword.fetch!(options, :runtime_purpose) == "application" do
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE=true is valid only for an application runtime"
    end

    unless Keyword.fetch!(options, :audio_provider_mode) == "livekit" do
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE=true requires AUDIO_PROVIDER_MODE=livekit"
    end

    require_loopback_hostname!(Keyword.fetch!(options, :phx_host), "PHX_HOST")

    require_origin!(
      Keyword.fetch!(options, :public_app_url),
      "PUBLIC_APP_URL",
      ["http"],
      @loopback_hosts
    )

    require_origin!(
      Keyword.fetch!(options, :livekit_server_url),
      "LIVEKIT_SERVER_URL",
      ["ws"],
      @loopback_hosts
    )

    require_origin!(
      Keyword.fetch!(options, :livekit_api_url),
      "LIVEKIT_API_URL",
      ["http"],
      ["livekit"],
      required_port: 7880
    )

    require_origin!(
      Keyword.fetch!(options, :s3_public_endpoint),
      "S3_PUBLIC_ENDPOINT",
      ["http"],
      @loopback_hosts
    )

    Keyword.fetch!(options, :cors_origins)
    |> require_origin_list!("CORS_ORIGINS", ["http"], @loopback_hosts)

    Keyword.fetch!(options, :csp_connect_sources)
    |> Enum.reject(&(&1 == "'self'"))
    |> require_origin_list!(
      "CSP_CONNECT_SOURCES",
      ["http", "ws"],
      @loopback_hosts
    )
  end

  defp require_loopback_hostname!(value, _name)
       when is_binary(value) and value in @loopback_hosts,
       do: :ok

  defp require_loopback_hostname!(_value, name) do
    raise ArgumentError,
          "#{name} must be localhost or a loopback address when K_COMMS_LOCAL_RELEASE=true"
  end

  defp require_origin_list!([], name, _schemes, _hosts) do
    raise ArgumentError,
          "#{name} must contain at least one loopback origin when K_COMMS_LOCAL_RELEASE=true"
  end

  defp require_origin_list!(values, name, schemes, hosts) when is_list(values) do
    Enum.each(values, &require_origin!(&1, name, schemes, hosts))
  end

  defp require_origin!(value, name, schemes, hosts, options \\ []) do
    uri = URI.parse(value || "")
    required_port = Keyword.get(options, :required_port)

    valid? =
      uri.scheme in schemes and uri.host in hosts and is_integer(uri.port) and
        (is_nil(required_port) or uri.port == required_port) and
        uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and
        is_nil(uri.fragment)

    unless valid? do
      target =
        if required_port,
          do: "#{Enum.join(schemes, "/")}://#{Enum.join(hosts, " or ")}:#{required_port}",
          else: "#{Enum.join(schemes, "/")} on an explicit loopback port"

      raise ArgumentError,
            "#{name} must be an exact #{target} origin when K_COMMS_LOCAL_RELEASE=true"
    end
  end
end
