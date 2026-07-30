defmodule CommsIntegrations.PinnedHttp.MintTransport do
  alias CommsIntegrations.PinnedHttp.ResponseAccumulator

  @default_timeout 10_000
  # Bound all response-header chunks to 32 KiB and 100 fields, independently
  # from the 1 MiB body budget.
  @default_max_response_bytes 1_048_576
  @default_max_response_header_bytes 32_768
  @default_max_response_header_count 100

  def request(destination, method, headers, body, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    configured_connect_timeout = Keyword.get(opts, :connect_timeout_ms, min(timeout, 5_000))
    deadline = Keyword.get_lazy(opts, :deadline_ms, fn -> monotonic_ms() + timeout end)
    mint_http = Keyword.get(opts, :mint_http, Mint.HTTP)

    response_limits = %{
      body_bytes: Keyword.get(opts, :max_response_bytes, @default_max_response_bytes),
      header_bytes:
        Keyword.get(
          opts,
          :max_response_header_bytes,
          @default_max_response_header_bytes
        ),
      header_count:
        Keyword.get(opts, :max_response_header_count, @default_max_response_header_count)
    }

    request_addresses(
      destination.addresses,
      destination,
      method,
      headers,
      body,
      deadline,
      configured_connect_timeout,
      response_limits,
      mint_http
    )
  end

  defp request_addresses(
         [],
         _destination,
         _method,
         _headers,
         _body,
         _deadline,
         _configured_connect_timeout,
         _response_limits,
         _mint_http
       ),
       do: {:error, :outbound_transport_error}

  defp request_addresses(
         [address | remaining_addresses],
         destination,
         method,
         headers,
         body,
         deadline,
         configured_connect_timeout,
         response_limits,
         mint_http
       ) do
    case request_address(
           destination,
           address,
           method,
           headers,
           body,
           deadline,
           configured_connect_timeout,
           response_limits,
           mint_http
         ) do
      {:ok, _response} = success ->
        success

      {:retry, reason} ->
        if remaining_addresses != [] and remaining_ms(deadline) > 0 do
          request_addresses(
            remaining_addresses,
            destination,
            method,
            headers,
            body,
            deadline,
            configured_connect_timeout,
            response_limits,
            mint_http
          )
        else
          {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp request_address(
         destination,
         address,
         method,
         headers,
         body,
         deadline,
         configured_connect_timeout,
         response_limits,
         mint_http
       ) do
    remaining = remaining_ms(deadline)

    if remaining == 0 do
      {:error, :outbound_timeout}
    else
      connect_timeout = min(configured_connect_timeout, max(div(remaining, 2), 1))
      send_timeout = max(remaining - connect_timeout, 1)

      connect_opts = [
        hostname: destination.host,
        mode: :passive,
        protocols: [:http1],
        transport_opts: [
          cacerts: :public_key.cacerts_get(),
          timeout: connect_timeout,
          send_timeout: send_timeout,
          inet6: tuple_size(address) == 8,
          inet4: true
        ]
      ]

      case mint_http.connect(:https, address, destination.port, connect_opts) do
        {:ok, conn} ->
          request_connected(
            mint_http,
            conn,
            method,
            destination,
            headers,
            body,
            deadline,
            response_limits
          )

        {:error, reason} ->
          connect_error(reason, deadline)
      end
    end
  rescue
    _ -> {:error, :outbound_transport_error}
  end

  defp request_connected(
         mint_http,
         conn,
         method,
         destination,
         headers,
         body,
         deadline,
         response_limits
       ) do
    if remaining_ms(deadline) == 0 do
      close(mint_http, conn)
      {:error, :outbound_timeout}
    else
      case mint_http.request(
             conn,
             method |> to_string() |> String.upcase(),
             request_target(destination.uri),
             headers,
             body
           ) do
        {:ok, next_conn, request_ref} ->
          receive_response(
            mint_http,
            next_conn,
            request_ref,
            deadline,
            response_limits,
            ResponseAccumulator.new()
          )

        {:error, next_conn, reason} ->
          close(mint_http, next_conn)
          {:error, normalize_transport_error(reason)}
      end
    end
  end

  defp receive_response(mint_http, conn, request_ref, deadline, response_limits, response) do
    remaining = remaining_ms(deadline)

    if remaining == 0 do
      close(mint_http, conn)
      {:error, :outbound_timeout}
    else
      case mint_http.recv(conn, 0, remaining) do
        {:ok, next_conn, entries} ->
          case ResponseAccumulator.consume(entries, request_ref, response, response_limits) do
            {:done, completed} ->
              close(mint_http, next_conn)
              {:ok, ResponseAccumulator.response(completed)}

            {:cont, next_response} ->
              receive_response(
                mint_http,
                next_conn,
                request_ref,
                deadline,
                response_limits,
                next_response
              )

            {:transport_error, reason} ->
              close(mint_http, next_conn)
              {:error, normalize_transport_error(reason)}

            {:error, reason} ->
              close(mint_http, next_conn)
              {:error, reason}
          end

        {:error, next_conn, reason, entries} ->
          consume_result =
            ResponseAccumulator.consume(entries, request_ref, response, response_limits)

          close(mint_http, next_conn)

          case consume_result do
            {:error, boundary_reason}
            when boundary_reason in [
                   :outbound_response_headers_too_large,
                   :outbound_response_too_large,
                   :outbound_invalid_response
                 ] ->
              {:error, boundary_reason}

            _other ->
              {:error, normalize_transport_error(reason)}
          end
      end
    end
  end

  defp request_target(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if is_binary(uri.query), do: path <> "?" <> uri.query, else: path
  end

  defp connect_error(reason, deadline) do
    case normalize_transport_error(reason) do
      :outbound_tls_error = error ->
        {:error, error}

      error ->
        if remaining_ms(deadline) == 0,
          do: {:retry, :outbound_timeout},
          else: {:retry, error}
    end
  end

  defp normalize_transport_error(%Mint.TransportError{reason: reason}),
    do: normalize_transport_error(reason)

  defp normalize_transport_error(:timeout), do: :outbound_timeout

  defp normalize_transport_error(reason) do
    if tls_error?(reason), do: :outbound_tls_error, else: :outbound_transport_error
  end

  defp tls_error?(:protocol_not_negotiated), do: true
  defp tls_error?({:bad_alpn_protocol, _protocol}), do: true
  defp tls_error?({:tls_alert, _alert}), do: true
  defp tls_error?({:options, _options}), do: true
  defp tls_error?(_reason), do: false

  defp remaining_ms(deadline), do: max(deadline - monotonic_ms(), 0)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp close(mint_http, conn) do
    _ = mint_http.close(conn)
    :ok
  end
end
