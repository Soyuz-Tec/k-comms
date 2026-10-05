defmodule CommsIntegrations.Calendar.Http do
  @moduledoc false
  alias CommsIntegrations.PinnedHttp
  @maximum_body 262_144

  # This typed adapter helper preserves one owner-supplied deadline through
  # DNS, token refresh, JWKS and provider effect. It never follows redirects.
  def request(method, url, headers, body, deadline, opts \\ [])

  def request(method, url, headers, body, deadline, opts)
      when is_integer(deadline) and is_binary(body) and byte_size(body) <= @maximum_body do
    host = URI.parse(url).host

    allowed = [
      "accounts.google.com",
      "oauth2.googleapis.com",
      "www.googleapis.com",
      "login.microsoftonline.com",
      "graph.microsoft.com",
      "openidconnect.googleapis.com"
    ]

    if host in allowed do
      opts =
        Keyword.take(opts, [:resolver, :transport, :mint_http]) ++
          [
            allowed_hosts: [host],
            allowed_ports: [443],
            deadline_ms: deadline,
            timeout_ms: 5_000,
            connect_timeout_ms: 2_000,
            max_response_bytes: @maximum_body,
            max_response_header_bytes: 16_384,
            max_response_header_count: 60
          ]

      case PinnedHttp.request(method, url, headers, body, opts) do
        {:ok, %{status: status, headers: response_headers, body: response_body} = response}
        when is_integer(status) and status in 100..599 and is_list(response_headers) and
               is_binary(response_body) and byte_size(response_body) <= @maximum_body ->
          if System.monotonic_time(:millisecond) < deadline,
            do: {:ok, response},
            else: {:error, :calendar_provider_timeout}

        {:error, :outbound_timeout} ->
          {:error, :calendar_provider_timeout}

        _ ->
          {:error, :calendar_provider_unavailable}
      end
    else
      {:error, :calendar_provider_unavailable}
    end
  end

  def request(_, _, _, _, _, _), do: {:error, :invalid_calendar_provider_request}

  def json(body) when is_binary(body) and byte_size(body) <= @maximum_body do
    with {:ok, value} when is_map(value) <- Jason.decode(body),
         true <- bounded_tree?(value, 0) do
      {:ok, value}
    else
      _ -> {:error, :invalid_calendar_provider_response}
    end
  end

  def json(_), do: {:error, :invalid_calendar_provider_response}

  def retry_after(headers) do
    case Enum.find(headers, fn {name, _} -> String.downcase(name) == "retry-after" end) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> min(seconds, 3600)
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp bounded_tree?(_, depth) when depth > 12, do: false

  defp bounded_tree?(value, depth) when is_map(value),
    do:
      map_size(value) <= 100 and
        Enum.all?(value, fn {key, item} ->
          is_binary(key) and byte_size(key) <= 256 and bounded_tree?(item, depth + 1)
        end)

  defp bounded_tree?(value, depth) when is_list(value),
    do:
      length(value) <= 100 and
        Enum.all?(value, &bounded_tree?(&1, depth + 1))

  defp bounded_tree?(value, _) when is_binary(value), do: byte_size(value) <= 65_536
  defp bounded_tree?(value, _), do: is_number(value) or is_boolean(value) or is_nil(value)
end
