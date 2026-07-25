defmodule CommsIntegrations.LocalReleaseGuard do
  @moduledoc """
  Fail-closed validation for the packaged qualification runtime.

  This guard does not weaken the production provider contract. It permits
  clear-text HTTP and WebSocket origins only when an operator explicitly
  enables both the local-release gate and the existing development-adapter
  gate. The default remains the fixed loopback Compose topology. An explicit
  release host may select one exact RFC1918 IPv4 address for controlled
  private-LAN evaluation. A separately confirmed, disposable qualification
  application may use one exact loopback browser origin without changing the
  retained release host or its content-security policy.
  """

  @loopback_hosts ["127.0.0.1", "::1", "localhost"]
  @qualification_app_confirmation "local-release-qualification-app-v1"
  @qualification_tenant_slug ~r/\Ak-comms-qualification-[0-9a-f]{32}\z/
  @qualification_app_port_range 1_024..65_535

  @spec validate!(keyword()) :: :ok
  def validate!(options) do
    enabled? = Keyword.fetch!(options, :enabled?)

    cond do
      enabled? ->
        validate_enabled!(options)

      qualification_app_requested?(options) ->
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires K_COMMS_LOCAL_RELEASE=true"

      true ->
        :ok
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

    qualification_app_origin = qualification_app_origin!(options)
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

    cors_origins = Keyword.fetch!(options, :cors_origins)

    if qualification_app_origin do
      require_qualification_cors!(cors_origins, qualification_app_origin)
    else
      require_origin_list!(cors_origins, "CORS_ORIGINS", ["http"], public_hosts)
    end

    Keyword.fetch!(options, :csp_connect_sources)
    |> Enum.reject(&(&1 == "'self'"))
    |> require_origin_list!(
      "CSP_CONNECT_SOURCES",
      ["http", "ws"],
      public_hosts
    )
  end

  defp qualification_app_requested?(options) do
    not is_nil(Keyword.get(options, :qualification_app_origin)) or
      not is_nil(Keyword.get(options, :qualification_app_confirmation))
  end

  defp qualification_app_origin!(options) do
    if qualification_app_requested?(options) do
      confirmation = Keyword.get(options, :qualification_app_confirmation)

      unless confirmation == @qualification_app_confirmation do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_CONFIRMATION must exactly equal " <>
                @qualification_app_confirmation
      end

      unless Keyword.get(options, :role) == "edge" do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires K_COMMS_ROLE=edge"
      end

      unless Keyword.fetch!(options, :runtime_purpose) == "application" do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires " <>
                "K_COMMS_RUNTIME_PURPOSE=application"
      end

      unless Keyword.get(options, :allow_bootstrap?) == false do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires ALLOW_BOOTSTRAP=false"
      end

      tenant_slug = Keyword.get(options, :instant_room_tenant_slug)

      unless is_binary(tenant_slug) and Regex.match?(@qualification_tenant_slug, tenant_slug) do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires INSTANT_ROOM_TENANT_SLUG " <>
                "to match k-comms-qualification-<32 lowercase hex characters>"
      end

      origin = Keyword.get(options, :qualification_app_origin)
      require_qualification_app_origin!(origin, Keyword.fetch!(options, :public_app_url))
      origin
    end
  end

  defp require_qualification_app_origin!(origin, public_app_url) do
    match =
      if is_binary(origin) do
        Regex.run(~r/\Ahttp:\/\/127\.0\.0\.1:([0-9]+)\z/, origin)
      end

    port =
      case match do
        [_, value] ->
          case Integer.parse(value) do
            {parsed, ""} -> if value == Integer.to_string(parsed), do: parsed
            _ -> nil
          end

        _ ->
          nil
      end

    public_app_port = URI.parse(public_app_url || "").port

    unless port in @qualification_app_port_range and port != public_app_port do
      raise ArgumentError,
            "K_COMMS_QUALIFICATION_APP_ORIGIN must be an exact canonical " <>
              "http://127.0.0.1:<non-public port> origin"
    end
  end

  defp require_qualification_cors!(values, qualification_app_origin) do
    unless values == [qualification_app_origin] do
      raise ArgumentError,
            "CORS_ORIGINS must contain exactly K_COMMS_QUALIFICATION_APP_ORIGIN " <>
              "for the isolated qualification application"
    end
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
