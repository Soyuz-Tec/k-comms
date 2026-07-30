defmodule CommsIntegrations.LocalReleaseGuard.OriginPolicy do
  @moduledoc false

  @loopback_hosts ["127.0.0.1", "::1", "localhost"]
  @trusted_edge_exposure_mode "cloudflare_trusted_edge"

  def require_public_origin!(value, name, scheme) do
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

  def normalize_hostname!(value, name) do
    case normalize_hostname(value, name) do
      nil ->
        raise ArgumentError,
              "#{name} must be one canonical DNS hostname in trusted-edge mode"

      host ->
        host
    end
  end

  def normalize_hostname(value, _name) when is_binary(value) do
    normalized = String.downcase(value)

    if value == normalized and value == String.trim(value) and
         normalized == String.trim_trailing(normalized, ".") do
      normalized
    end
  end

  def normalize_hostname(_value, _name), do: nil

  def public_dns_hostname?(host) do
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

  def origin_identity(value, expected_scheme) do
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

  def canonical_private_ipv4_host_cidr?(value) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [address, "32"] ->
        value == String.trim(value) and private_rfc1918_ipv4?(address)

      _ ->
        false
    end
  end

  def canonical_private_ipv4_host_cidr?(_value), do: false

  def canonical_private_http_origin_on_port?(value, public_app_url)
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

  def canonical_private_http_origin_on_port?(_value, _public_app_url), do: false

  def canonical_public_https_origin?(value) when is_binary(value) do
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

  def private_rfc1918_ipv4?(value) do
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

  def release_hosts!(nil), do: @loopback_hosts

  def release_hosts!(value) when is_binary(value) do
    if value in @loopback_hosts or private_rfc1918_ipv4?(value) do
      [value]
    else
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE_HOST must be an exact loopback host or canonical RFC1918 IPv4 address"
    end
  end

  def release_hosts!(_value) do
    raise ArgumentError,
          "K_COMMS_LOCAL_RELEASE_HOST must be an exact loopback host or canonical RFC1918 IPv4 address"
  end

  def require_release_hostname!(value, name, hosts) do
    unless is_binary(value) and value in hosts do
      target =
        if hosts == @loopback_hosts,
          do: "localhost or a loopback address",
          else: "K_COMMS_LOCAL_RELEASE_HOST=#{hd(hosts)}"

      raise ArgumentError,
            "#{name} must exactly match #{target} when K_COMMS_LOCAL_RELEASE=true"
    end
  end

  def require_origin_list!([], name, _schemes, _hosts) do
    raise ArgumentError,
          "#{name} must contain at least one release origin when K_COMMS_LOCAL_RELEASE=true"
  end

  def require_origin_list!(values, name, schemes, hosts) when is_list(values) do
    Enum.each(values, &require_origin!(&1, name, schemes, hosts))
  end

  def require_origin!(value, name, schemes, hosts, options \\ []) do
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
