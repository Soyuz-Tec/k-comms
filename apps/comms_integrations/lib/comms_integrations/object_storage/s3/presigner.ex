defmodule CommsIntegrations.ObjectStorage.S3.Presigner do
  @moduledoc false

  alias CommsIntegrations.ObjectStorage.S3.EndpointPolicy

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"
  @default_expires_in 900
  @default_download_expires_in 120
  @minimum_expires_in 60
  @maximum_expires_in 3_600

  def presign(method, object_key, endpoint, request_headers, extra_query),
    do: presign(method, object_key, endpoint, request_headers, extra_query, :default)

  def presign(method, object_key, endpoint, request_headers, extra_query, purpose) do
    config = Application.get_env(:comms_integrations, :s3, [])

    with {:ok, scheme} <- endpoint_value(config, endpoint, :scheme),
         {:ok, host} <- endpoint_value(config, endpoint, :host),
         {:ok, port} <- endpoint_value(config, endpoint, :port),
         {:ok, bucket} <- required(config, :bucket),
         {:ok, region} <- required(config, :region),
         {:ok, access_key} <- required(config, :access_key_id),
         {:ok, secret_key} <- required(config, :secret_access_key),
         :ok <- EndpointPolicy.validate(endpoint, scheme, host, port) do
      expires_in = expires_in(config, purpose)
      now = DateTime.utc_now()
      date = Calendar.strftime(now, "%Y%m%d")
      timestamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      scope = "#{date}/#{region}/#{@service}/aws4_request"
      host_header = host_header(scheme, host, port)
      canonical_uri = "/#{path(bucket)}/#{path(object_key)}"
      request_headers = normalize_headers(request_headers)
      signed_headers = Map.put(request_headers, "host", host_header)
      signed_header_names = signed_headers |> Map.keys() |> Enum.sort() |> Enum.join(";")

      canonical_headers =
        signed_headers
        |> Enum.sort_by(fn {name, _value} -> name end)
        |> Enum.map_join(fn {name, value} -> "#{name}:#{value}\n" end)

      query =
        extra_query ++
          [
            {"X-Amz-Algorithm", @algorithm},
            {"X-Amz-Credential", "#{access_key}/#{scope}"},
            {"X-Amz-Date", timestamp},
            {"X-Amz-Expires", Integer.to_string(expires_in)},
            {"X-Amz-SignedHeaders", signed_header_names}
          ]

      canonical_query = canonical_query(query)

      canonical_request =
        Enum.join(
          [
            method,
            canonical_uri,
            canonical_query,
            canonical_headers,
            signed_header_names,
            "UNSIGNED-PAYLOAD"
          ],
          "\n"
        )

      string_to_sign =
        Enum.join(
          [@algorithm, timestamp, scope, sha256_hex(canonical_request)],
          "\n"
        )

      signature =
        signing_key(secret_key, date, region)
        |> hmac(string_to_sign)
        |> Base.encode16(case: :lower)

      url =
        "#{scheme}://#{host_header}#{canonical_uri}?#{canonical_query}&X-Amz-Signature=#{signature}"

      {:ok,
       %{
         method: method,
         url: url,
         approved_origin: "#{scheme}://#{host_header}",
         development_http: scheme == "http",
         headers: request_headers,
         expires_in: expires_in,
         expires_at: DateTime.add(now, expires_in, :second)
       }}
    end
  end

  def encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp expires_in(config, :download) do
    config
    |> Keyword.get(:download_expires_in, @default_download_expires_in)
    |> min(Keyword.get(config, :expires_in, @default_expires_in))
    |> min(@maximum_expires_in)
    |> max(@minimum_expires_in)
  end

  defp expires_in(config, _purpose) do
    config
    |> Keyword.get(:expires_in, @default_expires_in)
    |> min(@maximum_expires_in)
    |> max(@minimum_expires_in)
  end

  defp signing_key(secret, date, region) do
    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  defp canonical_query(values) do
    values
    |> Enum.map(fn {key, value} -> {encode(key), encode(value)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      normalized_name = name |> to_string() |> String.trim() |> String.downcase()
      normalized_value = value |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ")
      {normalized_name, normalized_value}
    end)
  end

  defp path(value), do: value |> String.split("/") |> Enum.map_join("/", &encode/1)

  defp host_header(scheme, host, port) when {scheme, port} in [{"http", 80}, {"https", 443}],
    do: host

  defp host_header(_scheme, host, port), do: "#{host}:#{port}"

  defp required(config, key) do
    case Keyword.get(config, key) do
      value when value not in [nil, ""] -> {:ok, value}
      _ -> {:error, {:missing_s3_config, key}}
    end
  end

  defp endpoint_value(config, :public, key), do: required(config, key)

  defp endpoint_value(config, :internal, key) do
    case Keyword.get(config, internal_key(key)) do
      value when value not in [nil, ""] -> {:ok, value}
      _ -> required(config, key)
    end
  end

  defp internal_key(:scheme), do: :internal_scheme
  defp internal_key(:host), do: :internal_host
  defp internal_key(:port), do: :internal_port

  defp sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp hmac(key, value), do: :crypto.mac(:hmac, :sha256, key, value)
end
