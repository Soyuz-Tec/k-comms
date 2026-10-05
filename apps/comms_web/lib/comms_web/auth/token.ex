defmodule CommsWeb.Auth.Token do
  @behaviour CommsWeb.Auth
  @ticket_header "x-k-comms-socket-ticket"

  @impl true
  def authenticate(params, connect_info) when is_map(params) and is_map(connect_info) do
    # Native transports use headers. Reject ambiguous sources before consuming
    # any ticket; both transports retain the same one-use/current-identity owner.
    query_tickets =
      for key <- ["socket_ticket", :socket_ticket],
          Map.has_key?(params, key),
          do: Map.fetch!(params, key)

    case header_tickets(Map.get(connect_info, :x_headers, [])) do
      {:ok, headers} ->
        case query_tickets ++ headers do
          [ticket] when is_binary(ticket) and ticket != "" ->
            CommsCore.Accounts.consume_socket_ticket(ticket)

          _ ->
            {:error, :invalid_socket_ticket}
        end

      :error ->
        {:error, :invalid_socket_ticket}
    end
  end

  def authenticate(_, _), do: {:error, :invalid_socket_ticket}

  defp header_tickets(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, tickets} when is_binary(name) ->
        if String.downcase(name) == @ticket_header do
          if is_binary(value), do: {:cont, {:ok, [value | tickets]}}, else: {:halt, :error}
        else
          {:cont, {:ok, tickets}}
        end

      _other, result ->
        {:cont, result}
    end)
  end

  defp header_tickets(_), do: :error
end
