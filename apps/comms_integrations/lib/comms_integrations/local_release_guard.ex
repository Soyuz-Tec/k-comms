defmodule CommsIntegrations.LocalReleaseGuard do
  @moduledoc """
  Fail-closed validation for the packaged qualification runtime.

  This guard does not weaken the production provider contract. It permits
  clear-text HTTP and WebSocket origins only when an operator explicitly
  enables both the local-release gate and the existing development-adapter
  gate. The default remains the fixed loopback Compose topology. An explicit
  release host may select one exact RFC1918 IPv4 address for controlled
  private-LAN evaluation.
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

    public_hosts = release_hosts!(Keyword.fetch!(options, :local_release_host))

    require_release_hostname!(
      Keyword.fetch!(options, :phx_host),
      "PHX_HOST",
      public_hosts
    )

    require_origin!(
      Keyword.fetch!(options, :public_app_url),
      "PUBLIC_APP_URL",
      ["http"],
      public_hosts
    )

    require_origin!(
      Keyword.fetch!(options, :livekit_server_url),
      "LIVEKIT_SERVER_URL",
      ["ws"],
      public_hosts
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
      public_hosts
    )

    Keyword.fetch!(options, :cors_origins)
    |> require_origin_list!("CORS_ORIGINS", ["http"], public_hosts)

    Keyword.fetch!(options, :csp_connect_sources)
    |> Enum.reject(&(&1 == "'self'"))
    |> require_origin_list!(
      "CSP_CONNECT_SOURCES",
      ["http", "ws"],
      public_hosts
    )
  end

  defp release_hosts!(nil), do: @loopback_hosts

  defp release_hosts!(value) when is_binary(value) do
    if value in @loopback_hosts or private_rfc1918_ipv4?(value) do
      [value]
    else
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE_HOST must be an exact loopback host or canonical RFC1918 IPv4 address"
    end
  end

  defp release_hosts!(_value) do
    raise ArgumentError,
          "K_COMMS_LOCAL_RELEASE_HOST must be an exact loopback host or canonical RFC1918 IPv4 address"
  end

  defp private_rfc1918_ipv4?(value) do
    with {:ok, address} <- :inet.parse_ipv4_address(String.to_charlist(value)),
         true <- address |> :inet.ntoa() |> to_string() == value do
      case address do
        {10, _, _, _} -> true
        {172, second, _, _} when second in 16..31 -> true
        {192, 168, _, _} -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp require_release_hostname!(value, name, hosts) do
    unless is_binary(value) and value in hosts do
      target =
        if hosts == @loopback_hosts,
          do: "localhost or a loopback address",
          else: "K_COMMS_LOCAL_RELEASE_HOST=#{hd(hosts)}"

      raise ArgumentError,
            "#{name} must exactly match #{target} when K_COMMS_LOCAL_RELEASE=true"
    end
  end

  defp require_origin_list!([], name, _schemes, _hosts) do
    raise ArgumentError,
          "#{name} must contain at least one release origin when K_COMMS_LOCAL_RELEASE=true"
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
          else: "#{Enum.join(schemes, "/")}://#{Enum.join(hosts, " or ")} on an explicit port"

      raise ArgumentError,
            "#{name} must be an exact #{target} origin when K_COMMS_LOCAL_RELEASE=true"
    end
  end
end
