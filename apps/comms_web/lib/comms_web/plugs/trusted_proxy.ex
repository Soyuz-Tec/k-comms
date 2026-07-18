defmodule CommsWeb.Plugs.TrustedProxy do
  @moduledoc """
  Accepts `X-Forwarded-For` only from explicitly configured proxy networks.

  The right-most untrusted address is selected so an attacker-controlled value
  prepended to the chain cannot replace the client address added by a trusted
  ingress. Invalid or ambiguous headers fail closed to the socket peer.
  """

  import Bitwise
  import Plug.Conn

  @max_forwarded_addresses 20

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    client = client_address(conn.remote_ip, get_req_header(conn, "x-forwarded-for"))
    %{conn | remote_ip: client}
  end

  @doc false
  def client_address(peer_address, forwarded_values) do
    trusted_networks =
      :comms_web
      |> Application.get_env(:trusted_proxy_cidrs, [])
      |> Enum.flat_map(&parse_network/1)

    if trusted?(peer_address, trusted_networks) do
      case forwarded_chain(forwarded_values) do
        {:ok, addresses} ->
          addresses
          |> Enum.reverse()
          |> Enum.find(&(not trusted?(&1, trusted_networks)))
          |> then(&(&1 || peer_address))

        :error ->
          peer_address
      end
    else
      peer_address
    end
  end

  defp forwarded_chain(forwarded_values) do
    case forwarded_values do
      [header] ->
        addresses =
          header
          |> String.split(",", trim: true)
          |> Enum.map(&(&1 |> String.trim() |> parse_address()))

        if addresses != [] and length(addresses) <= @max_forwarded_addresses and
             Enum.all?(addresses, &match?({:ok, _}, &1)) do
          {:ok, Enum.map(addresses, fn {:ok, address} -> address end)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp parse_network(value) when is_binary(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [address] -> network(address, nil)
      [address, prefix] -> network(address, prefix)
      _ -> []
    end
  end

  defp parse_network(_), do: []

  defp network(address, prefix_text) do
    with {:ok, parsed} <- parse_address(address),
         {family, _value, bits} <- address_integer(parsed),
         {:ok, prefix} <- parse_prefix(prefix_text, bits) do
      [{family, parsed, prefix}]
    else
      _ -> []
    end
  end

  defp parse_prefix(nil, bits), do: {:ok, bits}

  defp parse_prefix(text, bits) do
    case Integer.parse(text) do
      {prefix, ""} when prefix >= 0 and prefix <= bits -> {:ok, prefix}
      _ -> :error
    end
  end

  defp trusted?(address, networks) do
    case address_integer(address) do
      {family, value, bits} ->
        Enum.any?(networks, fn
          {^family, network, prefix} ->
            {^family, network_value, ^bits} = address_integer(network)
            shift = bits - prefix
            value >>> shift == network_value >>> shift

          _ ->
            false
        end)

      :error ->
        false
    end
  end

  defp parse_address(text) do
    case :inet.parse_address(String.to_charlist(text)) do
      {:ok, address} -> {:ok, address}
      {:error, _} -> :error
    end
  end

  defp address_integer({a, b, c, d}) do
    {:ipv4, a * 16_777_216 + b * 65_536 + c * 256 + d, 32}
  end

  defp address_integer(address) when is_tuple(address) and tuple_size(address) == 8 do
    value =
      address
      |> Tuple.to_list()
      |> Enum.reduce(0, fn segment, accumulator -> (accumulator <<< 16) + segment end)

    {:ipv6, value, 128}
  end

  defp address_integer(_), do: :error
end
