defmodule CommsIntegrations.PinnedHttp.ResponseAccumulator do
  @moduledoc false

  def new do
    %{
      status: nil,
      headers: [],
      header_bytes: 0,
      header_count: 0,
      body: [],
      body_bytes: 0
    }
  end

  def consume(entries, request_ref, response, response_limits) do
    Enum.reduce_while(entries, {:cont, response}, fn
      {:status, ^request_ref, status}, {:cont, acc} ->
        {:cont, {:cont, %{acc | status: status}}}

      {:headers, ^request_ref, headers}, {:cont, acc} ->
        case consume_headers(headers, acc, response_limits) do
          {:ok, next_acc} -> {:cont, {:cont, next_acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:data, ^request_ref, data}, {:cont, acc} ->
        bytes = acc.body_bytes + byte_size(data)

        if bytes <= response_limits.body_bytes do
          {:cont, {:cont, %{acc | body: [acc.body, data], body_bytes: bytes}}}
        else
          {:halt, {:error, :outbound_response_too_large}}
        end

      {:done, ^request_ref}, {:cont, acc} ->
        if is_integer(acc.status),
          do: {:halt, {:done, acc}},
          else: {:halt, {:error, :outbound_invalid_response}}

      {:error, ^request_ref, reason}, {:cont, _acc} ->
        {:halt, {:transport_error, reason}}

      _entry, state ->
        {:cont, state}
    end)
  end

  def response(accumulator) do
    %{
      status: accumulator.status,
      headers: accumulator.headers,
      body: IO.iodata_to_binary(accumulator.body)
    }
  end

  defp consume_headers(headers, response, limits) when is_list(headers) do
    case header_totals(headers, response.header_bytes, response.header_count, limits) do
      {:ok, header_bytes, header_count} ->
        {:ok,
         %{
           response
           | headers: response.headers ++ headers,
             header_bytes: header_bytes,
             header_count: header_count
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp consume_headers(_headers, _response, _limits),
    do: {:error, :outbound_invalid_response}

  defp header_totals(headers, initial_bytes, initial_count, limits) do
    Enum.reduce_while(headers, {:ok, initial_bytes, initial_count}, fn
      {name, value}, {:ok, bytes, count} when is_binary(name) and is_binary(value) ->
        # Include the `: ` separator and trailing CRLF from the HTTP wire representation.
        next_bytes = bytes + byte_size(name) + byte_size(value) + 4
        next_count = count + 1

        if next_bytes <= limits.header_bytes and next_count <= limits.header_count,
          do: {:cont, {:ok, next_bytes, next_count}},
          else: {:halt, {:error, :outbound_response_headers_too_large}}

      _header, _totals ->
        {:halt, {:error, :outbound_invalid_response}}
    end)
  end
end
