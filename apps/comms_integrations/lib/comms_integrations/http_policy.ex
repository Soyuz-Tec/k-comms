defmodule CommsIntegrations.HttpPolicy do
  @type reason :: atom()

  def validate_https_destination(url, allowed_hosts, allowed_ports \\ [443], opts \\ []) do
    case resolve_https_destination(url, allowed_hosts, allowed_ports, opts) do
      {:ok, _destination} -> :ok
      {:error, _} = error -> error
    end
  end

  def resolve_https_destination(url, allowed_hosts, allowed_ports \\ [443], opts \\ []) do
    uri = URI.parse(url || "")
    host = normalize_host(uri.host)
    port = uri.port || 443
    allowed_hosts = Enum.map(allowed_hosts || [], &normalize_host/1)

    cond do
      uri.scheme != "https" -> {:error, :outbound_https_required}
      is_nil(host) or host == "" -> {:error, :outbound_host_required}
      not is_nil(uri.userinfo) -> {:error, :outbound_credentials_forbidden}
      not is_nil(uri.fragment) -> {:error, :outbound_fragment_forbidden}
      port not in allowed_ports -> {:error, :outbound_port_not_allowed}
      host not in allowed_hosts -> {:error, :outbound_host_not_allowed}
      ip_literal?(host) -> {:error, :outbound_ip_literal_forbidden}
      Keyword.get(opts, :resolve, true) -> resolve_and_validate(uri, host, port, opts)
      true -> {:ok, %{uri: uri, host: host, port: port, addresses: []}}
    end
  end

  def configuration_status(config, required_keys) when is_list(config) do
    missing = Enum.reject(required_keys, &configured?(Keyword.get(config, &1)))

    if missing == [] do
      %{status: :available}
    else
      %{status: :unavailable, reason: :missing_configuration, missing: missing}
    end
  end

  def https_configuration_status(config, required_keys) when is_list(config) do
    case configuration_status(config, required_keys) do
      %{status: :available} ->
        case validate_https_destination(
               Keyword.get(config, :endpoint),
               Keyword.get(config, :allowed_hosts, []),
               Keyword.get(config, :allowed_ports, [443]),
               resolve: false
             ) do
          :ok -> %{status: :available}
          {:error, reason} -> %{status: :unavailable, reason: reason}
        end

      status ->
        status
    end
  end

  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(value) when is_list(value), do: value != []
  defp configured?(_), do: false

  defp resolve_and_validate(uri, host, port, opts) do
    addresses = resolve_addresses(host, Keyword.get(opts, :resolver))

    cond do
      addresses == [] ->
        {:error, :outbound_dns_unavailable}

      Enum.all?(addresses, &public_address?/1) ->
        {:ok, %{uri: uri, host: host, port: port, addresses: addresses}}

      true ->
        {:error, :outbound_private_address_forbidden}
    end
  end

  defp resolve_addresses(host, resolver) when is_function(resolver, 1) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) -> Enum.uniq(addresses)
      addresses when is_list(addresses) -> Enum.uniq(addresses)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp resolve_addresses(host, _resolver), do: resolved_addresses(host)

  defp resolved_addresses(host) do
    ipv4 = resolved(host, :inet)
    ipv6 = resolved(host, :inet6)
    Enum.uniq(ipv4 ++ ipv6)
  end

  defp resolved(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end

  def public_address?({a, b, c, _d}) do
    cond do
      a == 0 -> false
      a == 10 -> false
      a == 100 and b in 64..127 -> false
      a == 127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 192 and b == 0 and c in [0, 2] -> false
      a == 198 and b in [18, 19] -> false
      a == 198 and b == 51 and c == 100 -> false
      a == 203 and b == 0 and c == 113 -> false
      a >= 224 -> false
      true -> true
    end
  end

  def public_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  def public_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  def public_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    public_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  def public_address?({first, second, _c, _d, _e, _f, _g, _h}) do
    cond do
      band(first, 0xFE00) == 0xFC00 -> false
      band(first, 0xFFC0) == 0xFE80 -> false
      band(first, 0xFFC0) == 0xFEC0 -> false
      band(first, 0xE000) != 0x2000 -> false
      first == 0x2001 and second == 0x0000 -> false
      first == 0x2001 and second == 0x0DB8 -> false
      first == 0x2002 -> false
      band(first, 0xFF00) == 0xFF00 -> false
      true -> true
    end
  end

  def public_address?(_), do: false

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp band(left, right), do: Bitwise.band(left, right)
end
