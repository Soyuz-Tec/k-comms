defmodule CommsIntegrations.PinnedHttp do
  alias CommsIntegrations.HttpPolicy

  def request(method, url, headers, body, opts) when is_list(opts) do
    allowed_hosts = Keyword.get(opts, :allowed_hosts, [])
    allowed_ports = Keyword.get(opts, :allowed_ports, [443])
    policy_opts = Keyword.take(opts, [:resolver])

    with {:ok, destination} <-
           HttpPolicy.resolve_https_destination(url, allowed_hosts, allowed_ports, policy_opts) do
      transport = Keyword.get(opts, :transport, __MODULE__.MintTransport)
      transport.request(destination, method, headers, body, opts)
    end
  end

  defmodule MintTransport do
    @default_timeout 10_000
    @default_max_response_bytes 1_048_576

    def request(destination, method, headers, body, opts) do
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
      connect_timeout = Keyword.get(opts, :connect_timeout_ms, min(timeout, 5_000))

      max_response_bytes =
        Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

      Enum.reduce_while(destination.addresses, {:error, :outbound_transport_error}, fn address,
                                                                                       _last ->
        case request_address(
               destination,
               address,
               method,
               headers,
               body,
               timeout,
               connect_timeout,
               max_response_bytes
             ) do
          {:ok, _response} = success -> {:halt, success}
          {:error, _} = error -> {:cont, error}
        end
      end)
    end

    defp request_address(
           destination,
           address,
           method,
           headers,
           body,
           timeout,
           connect_timeout,
           max_response_bytes
         ) do
      connect_opts = [
        hostname: destination.host,
        mode: :passive,
        protocols: [:http1],
        transport_opts: [
          cacerts: :public_key.cacerts_get(),
          timeout: connect_timeout,
          send_timeout: timeout,
          inet6: tuple_size(address) == 8,
          inet4: true
        ]
      ]

      with {:ok, conn} <- Mint.HTTP.connect(:https, address, destination.port, connect_opts),
           {:ok, conn, request_ref} <-
             Mint.HTTP.request(
               conn,
               method |> to_string() |> String.upcase(),
               request_target(destination.uri),
               headers,
               body
             ) do
        receive_response(conn, request_ref, timeout, max_response_bytes, %{
          status: nil,
          headers: [],
          body: [],
          body_bytes: 0
        })
      else
        {:error, _conn, _reason} -> {:error, :outbound_transport_error}
        {:error, _reason} -> {:error, :outbound_transport_error}
      end
    rescue
      _ -> {:error, :outbound_transport_error}
    end

    defp receive_response(conn, request_ref, timeout, max_response_bytes, response) do
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, next_conn, entries} ->
          case consume(entries, request_ref, response, max_response_bytes) do
            {:done, completed} ->
              close(next_conn)

              {:ok,
               %{
                 status: completed.status,
                 headers: completed.headers,
                 body: IO.iodata_to_binary(completed.body)
               }}

            {:cont, next_response} ->
              receive_response(next_conn, request_ref, timeout, max_response_bytes, next_response)

            {:error, reason} ->
              close(next_conn)
              {:error, reason}
          end

        {:error, next_conn, _reason, entries} ->
          _ = consume(entries, request_ref, response, max_response_bytes)
          close(next_conn)
          {:error, :outbound_transport_error}
      end
    end

    defp consume(entries, request_ref, response, max_response_bytes) do
      Enum.reduce_while(entries, {:cont, response}, fn
        {:status, ^request_ref, status}, {:cont, acc} ->
          {:cont, {:cont, %{acc | status: status}}}

        {:headers, ^request_ref, headers}, {:cont, acc} ->
          {:cont, {:cont, %{acc | headers: headers}}}

        {:data, ^request_ref, data}, {:cont, acc} ->
          bytes = acc.body_bytes + byte_size(data)

          if bytes <= max_response_bytes do
            {:cont, {:cont, %{acc | body: [acc.body, data], body_bytes: bytes}}}
          else
            {:halt, {:error, :outbound_response_too_large}}
          end

        {:done, ^request_ref}, {:cont, acc} ->
          if is_integer(acc.status),
            do: {:halt, {:done, acc}},
            else: {:halt, {:error, :outbound_invalid_response}}

        {:error, ^request_ref, _reason}, {:cont, _acc} ->
          {:halt, {:error, :outbound_transport_error}}

        _entry, state ->
          {:cont, state}
      end)
    end

    defp request_target(uri) do
      path = if uri.path in [nil, ""], do: "/", else: uri.path
      if is_binary(uri.query), do: path <> "?" <> uri.query, else: path
    end

    defp close(conn) do
      _ = Mint.HTTP.close(conn)
      :ok
    end
  end
end
