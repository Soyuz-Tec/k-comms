defmodule CommsWeb.UserSocket do
  use Phoenix.Socket

  @connection_limit 60
  @connection_window_seconds 60

  channel("conversation:*", CommsWeb.ConversationChannel)
  channel("user:*", CommsWeb.UserChannel)

  @impl true
  def connect(params, socket, connect_info) do
    key = {:socket_connection_ip, peer(connect_info)}

    if CommsWeb.RateLimiter.allow?(key, @connection_limit, @connection_window_seconds) do
      case CommsWeb.Auth.authenticate(params, connect_info) do
        {:ok, identity} ->
          socket =
            Enum.reduce(identity, socket, fn {key, value}, acc -> assign(acc, key, value) end)

          {:ok, socket}

        _ ->
          :error
      end
    else
      :error
    end
  end

  @impl true
  def id(socket), do: "session_socket:#{socket.assigns.session_id}"

  defp peer(%{peer_data: %{address: address}} = connect_info) when is_tuple(address) do
    forwarded_values = forwarded_values(Map.get(connect_info, :x_headers, []))

    address
    |> CommsWeb.Plugs.TrustedProxy.client_address(forwarded_values)
    |> :inet.ntoa()
    |> to_string()
  end

  defp peer(_connect_info), do: "unknown"

  defp forwarded_values(headers) when is_list(headers) do
    Enum.reduce(headers, [], fn
      {name, value}, values when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "x-forwarded-for", do: [value | values], else: values

      _header, values ->
        values
    end)
    |> Enum.reverse()
  end

  defp forwarded_values(_headers), do: []
end
