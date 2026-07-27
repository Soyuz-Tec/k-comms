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
  retained release host or its content-security policy. A distinct,
  operator-confirmed Cloudflare Tunnel profile permits only exact HTTPS/WSS
  public origins behind one narrowly trusted ingress network.
  """

  @loopback_hosts ["127.0.0.1", "::1", "localhost"]
  @qualification_app_confirmation "local-release-qualification-app-v1"
  @qualification_tenant_slug ~r/\Ak-comms-qualification-[0-9a-f]{32}\z/
  @qualification_app_port_range 1_024..65_535
  @trusted_edge_exposure_mode "cloudflare_trusted_edge"
  @trusted_edge_confirmation "cloudflare-tunnel-v1"
  @local_livekit_topology "local_sidecar"
  @managed_livekit_topology "managed_cloud"
  @managed_livekit_confirmation "livekit-cloud-v1"

  @spec validate!(keyword()) :: :ok
  def validate!(options) do
    enabled? = Keyword.fetch!(options, :enabled?)
    exposure_mode = Keyword.get(options, :exposure_mode)
    trusted_edge_confirmation = Keyword.get(options, :trusted_edge_confirmation)
    livekit_topology = Keyword.get(options, :livekit_topology, @local_livekit_topology)
    managed_livekit_confirmation = Keyword.get(options, :managed_livekit_confirmation)

    validate_livekit_topology!(livekit_topology, managed_livekit_confirmation)

    unless exposure_mode in [nil, "", @trusted_edge_exposure_mode] do
      raise ArgumentError,
            "K_COMMS_RELEASE_EXPOSURE_MODE must be unset or exactly " <>
              @trusted_edge_exposure_mode
    end

    cond do
      exposure_mode == @trusted_edge_exposure_mode and not enabled? ->
        raise ArgumentError,
              "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode} requires " <>
                "K_COMMS_LOCAL_RELEASE=true"

      enabled? ->
        validate_enabled!(
          options,
          exposure_mode,
          trusted_edge_confirmation,
          livekit_topology
        )

      qualification_app_requested?(options) ->
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires K_COMMS_LOCAL_RELEASE=true"

      trusted_edge_confirmation not in [nil, ""] ->
        raise ArgumentError,
              "K_COMMS_TRUSTED_EDGE_CONFIRMATION is valid only when " <>
                "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode}"

      true ->
        :ok
    end

    :ok
  end

  defp validate_enabled!(
         options,
         exposure_mode,
         trusted_edge_confirmation,
         livekit_topology
       ) do
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

    if exposure_mode == @trusted_edge_exposure_mode do
      validate_trusted_edge!(
        options,
        trusted_edge_confirmation,
        livekit_topology
      )
    else
      unless trusted_edge_confirmation in [nil, ""] do
        raise ArgumentError,
              "K_COMMS_TRUSTED_EDGE_CONFIRMATION is valid only when " <>
                "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode}"
      end

      validate_direct_release!(options, livekit_topology)
    end
  end

  defp validate_direct_release!(options, livekit_topology) do
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

    livekit_origin =
      require_livekit_topology_origins!(
        options,
        livekit_topology,
        public_hosts
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

    csp_connect_sources =
      options
      |> Keyword.fetch!(:csp_connect_sources)
      |> Enum.reject(&(&1 == "'self'"))

    if livekit_topology == @managed_livekit_topology do
      require_managed_livekit_csp!(
        csp_connect_sources,
        livekit_origin,
        public_hosts
      )
    else
      require_origin_list!(
        csp_connect_sources,
        "CSP_CONNECT_SOURCES",
        ["http", "ws"],
        public_hosts
      )
    end
  end

  defp validate_trusted_edge!(options, confirmation, livekit_topology) do
    unless confirmation == @trusted_edge_confirmation do
      raise ArgumentError,
            "K_COMMS_TRUSTED_EDGE_CONFIRMATION must exactly equal " <>
              @trusted_edge_confirmation
    end

    if qualification_app_requested?(options) do
      raise ArgumentError,
            "K_COMMS_QUALIFICATION_APP_ORIGIN is not valid with " <>
              "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode}"
    end

    public_app_url = Keyword.fetch!(options, :public_app_url)

    public_app_origin =
      require_public_origin!(
        public_app_url,
        "PUBLIC_APP_URL",
        "https"
      )

    phx_host =
      options
      |> Keyword.fetch!(:phx_host)
      |> normalize_hostname!("PHX_HOST")

    unless elem(public_app_origin, 1) == phx_host do
      raise ArgumentError,
            "PHX_HOST must exactly match the PUBLIC_APP_URL host in trusted-edge mode"
    end

    livekit_origin =
      require_public_origin!(
        Keyword.fetch!(options, :livekit_server_url),
        "LIVEKIT_SERVER_URL",
        "wss"
      )

    require_livekit_api_origin!(
      Keyword.fetch!(options, :livekit_api_url),
      livekit_origin,
      livekit_topology
    )

    object_origin =
      require_public_origin!(
        Keyword.fetch!(options, :s3_public_endpoint),
        "S3_PUBLIC_ENDPOINT",
        "https"
      )

    require_exact_cors!(
      Keyword.fetch!(options, :cors_origins),
      public_app_url
    )

    require_exact_csp!(
      Keyword.fetch!(options, :csp_connect_sources),
      livekit_origin,
      object_origin
    )

    unless Keyword.get(options, :hsts?, false) do
      raise ArgumentError,
            "HSTS_ENABLED must be true when " <>
              "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode}"
    end

    require_exact_trusted_proxy_cidr!(Keyword.get(options, :trusted_proxy_cidrs, []))
  end

  defp validate_livekit_topology!(
         @local_livekit_topology,
         confirmation
       )
       when confirmation in [nil, ""],
       do: :ok

  defp validate_livekit_topology!(@local_livekit_topology, _confirmation) do
    raise ArgumentError,
          "K_COMMS_MANAGED_LIVEKIT_CONFIRMATION is valid only when " <>
            "K_COMMS_LIVEKIT_TOPOLOGY=#{@managed_livekit_topology}"
  end

  defp validate_livekit_topology!(
         @managed_livekit_topology,
         @managed_livekit_confirmation
       ),
       do: :ok

  defp validate_livekit_topology!(@managed_livekit_topology, _confirmation) do
    raise ArgumentError,
          "K_COMMS_MANAGED_LIVEKIT_CONFIRMATION must exactly equal " <>
            @managed_livekit_confirmation
  end

  defp validate_livekit_topology!(_topology, _confirmation) do
    raise ArgumentError,
          "K_COMMS_LIVEKIT_TOPOLOGY must be exactly " <>
            "#{@local_livekit_topology} or #{@managed_livekit_topology}"
  end

  defp require_livekit_topology_origins!(
         options,
         @local_livekit_topology,
         public_hosts
       ) do
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

    nil
  end

  defp require_livekit_topology_origins!(
         options,
         @managed_livekit_topology,
         _public_hosts
       ) do
    livekit_origin =
      require_public_origin!(
        Keyword.fetch!(options, :livekit_server_url),
        "LIVEKIT_SERVER_URL",
        "wss"
      )

    require_livekit_api_origin!(
      Keyword.fetch!(options, :livekit_api_url),
      livekit_origin,
      @managed_livekit_topology
    )

    livekit_origin
  end

  defp require_livekit_api_origin!(
         value,
         _livekit_origin,
         @local_livekit_topology
       ) do
    require_origin!(
      value,
      "LIVEKIT_API_URL",
      ["http"],
      ["livekit"],
      required_port: 7880
    )
  end

  defp require_livekit_api_origin!(
         value,
         {_scheme, livekit_host, _port},
         @managed_livekit_topology
       ) do
    case require_public_origin!(value, "LIVEKIT_API_URL", "https") do
      {"https", ^livekit_host, 443} ->
        :ok

      _ ->
        raise ArgumentError,
              "LIVEKIT_API_URL must use the same public host as " <>
                "LIVEKIT_SERVER_URL in managed-cloud mode"
    end
  end

  defp require_managed_livekit_csp!(values, livekit_origin, public_hosts) do
    {livekit_values, local_values} =
      Enum.split_with(values, fn value ->
        origin_identity(value, "wss") == {:ok, livekit_origin}
      end)

    unless length(livekit_values) == 1 do
      raise ArgumentError,
            "CSP_CONNECT_SOURCES must contain LIVEKIT_SERVER_URL exactly once " <>
              "in managed-cloud mode"
    end

    require_origin_list!(
      local_values,
      "CSP_CONNECT_SOURCES",
      ["http", "ws"],
      public_hosts
    )
  end

  defp require_public_origin!(value, name, scheme) do
    uri = URI.parse(value || "")
    host = normalize_hostname(uri.host, name)

    valid? =
      is_binary(value) and value == String.trim(value) and uri.scheme == scheme and
        is_binary(host) and uri.port == 443 and uri.path in [nil, "", "/"] and
        is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
        public_dns_hostname?(host) and value == "#{scheme}://#{host}"

    unless valid? do
      raise ArgumentError,
            "#{name} must be an exact public #{String.upcase(scheme)} origin on port 443 " <>
              "when K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode}"
    end

    {scheme, host, 443}
  end

  defp normalize_hostname!(value, name) do
    case normalize_hostname(value, name) do
      nil ->
        raise ArgumentError,
              "#{name} must be one canonical DNS hostname in trusted-edge mode"

      host ->
        host
    end
  end

  defp normalize_hostname(value, _name) when is_binary(value) do
    normalized = String.downcase(value)

    if value == normalized and value == String.trim(value) and
         normalized == String.trim_trailing(normalized, ".") do
      normalized
    end
  end

  defp normalize_hostname(_value, _name), do: nil

  defp public_dns_hostname?(host) do
    byte_size(host) in 1..253 and
      not String.ends_with?(host, ".invalid") and
      not String.ends_with?(host, ".localhost") and
      host != "localhost" and
      match?({:error, _}, :inet.parse_address(String.to_charlist(host))) and
      host
      |> String.split(".")
      |> then(
        &(length(&1) >= 2 and
            Enum.all?(&1, fn label ->
              byte_size(label) in 1..63 and
                Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
            end))
      )
  end

  defp require_exact_cors!(values, public_app_url) do
    unless values == [public_app_url] do
      raise ArgumentError,
            "CORS_ORIGINS must contain exactly PUBLIC_APP_URL in trusted-edge mode"
    end
  end

  defp require_exact_csp!(values, livekit_origin, object_origin) do
    valid? =
      case values do
        ["'self'", livekit, object] ->
          origin_identity(livekit, "wss") == {:ok, livekit_origin} and
            origin_identity(object, "https") == {:ok, object_origin}

        _ ->
          false
      end

    unless valid? do
      raise ArgumentError,
            "CSP_CONNECT_SOURCES must contain exactly 'self', LIVEKIT_SERVER_URL, " <>
              "and S3_PUBLIC_ENDPOINT in trusted-edge mode"
    end
  end

  defp origin_identity(value, expected_scheme) do
    uri = URI.parse(value || "")
    host = normalize_hostname(uri.host, "origin")

    if is_binary(value) and value == String.trim(value) and uri.scheme == expected_scheme and
         is_binary(host) and uri.port == 443 and uri.path in [nil, "", "/"] and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, {expected_scheme, host, 443}}
    else
      :error
    end
  end

  defp require_exact_trusted_proxy_cidr!([value]) do
    unless canonical_private_ipv4_host_cidr?(value) do
      raise ArgumentError,
            "TRUSTED_PROXY_CIDRS must contain exactly one canonical private IPv4 /32 " <>
              "in trusted-edge mode"
    end
  end

  defp require_exact_trusted_proxy_cidr!(_values) do
    raise ArgumentError,
          "TRUSTED_PROXY_CIDRS must contain exactly one canonical private IPv4 /32 " <>
            "in trusted-edge mode"
  end

  defp canonical_private_ipv4_host_cidr?(value) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [address, "32"] ->
        value == String.trim(value) and private_rfc1918_ipv4?(address)

      _ ->
        false
    end
  end

  defp canonical_private_ipv4_host_cidr?(_value), do: false

  defp qualification_app_requested?(options) do
    not is_nil(Keyword.get(options, :qualification_app_origin)) or
      not is_nil(Keyword.get(options, :qualification_app_confirmation)) or
      not is_nil(Keyword.get(options, :qualification_share_origin))
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

      require_qualification_share_origin!(
        Keyword.get(options, :qualification_share_origin),
        Keyword.fetch!(options, :public_app_url),
        origin
      )

      origin
    end
  end

  defp require_qualification_share_origin!(share_origin, public_app_url, app_origin) do
    valid? =
      is_binary(share_origin) and share_origin != app_origin and
        (share_origin == public_app_url or
           canonical_private_http_origin_on_port?(share_origin, public_app_url) or
           canonical_public_https_origin?(share_origin))

    unless valid? do
      raise ArgumentError,
            "K_COMMS_QUALIFICATION_SHARE_ORIGIN must exactly equal PUBLIC_APP_URL " <>
              "or be one canonical RFC1918 HTTP origin on the same port or " <>
              "one canonical public HTTPS origin on port 443"
    end
  end

  defp canonical_private_http_origin_on_port?(value, public_app_url)
       when is_binary(value) and is_binary(public_app_url) do
    try do
      uri = URI.parse(value)
      public_uri = URI.parse(public_app_url)

      value == String.trim(value) and uri.scheme == "http" and
        is_binary(uri.host) and private_rfc1918_ipv4?(uri.host) and
        uri.port == public_uri.port and uri.port in 1..65_535 and
        uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and
        is_nil(uri.query) and is_nil(uri.fragment) and
        value == "http://#{uri.host}:#{uri.port}"
    rescue
      URI.Error -> false
    end
  end

  defp canonical_private_http_origin_on_port?(_value, _public_app_url), do: false

  defp canonical_public_https_origin?(value) when is_binary(value) do
    try do
      uri = URI.parse(value)
      host = normalize_hostname(uri.host, "K_COMMS_QUALIFICATION_SHARE_ORIGIN")

      value == String.trim(value) and uri.scheme == "https" and
        is_binary(host) and uri.port == 443 and uri.path in [nil, "", "/"] and
        is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
        public_dns_hostname?(host) and value == "https://#{host}"
    rescue
      URI.Error -> false
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
