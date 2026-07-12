defmodule CommsIntegrations.ObjectStorage.S3 do
  @behaviour CommsIntegrations.ObjectStorage

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"

  @impl true
  def presign_upload(attachment) do
    headers = %{"content-type" => attachment.content_type}

    headers =
      if is_binary(attachment.checksum_sha256) do
        Map.put(headers, "x-amz-meta-sha256", attachment.checksum_sha256)
      else
        headers
      end

    presign("PUT", attachment.object_key, :public, headers)
  end

  @impl true
  def presign_download(attachment), do: presign("GET", attachment.object_key)

  @impl true
  def verify_upload(attachment) do
    with {:ok, %{url: url}} <- presign("HEAD", attachment.object_key, :internal),
         request <- Finch.build(:head, url),
         {:ok, %Finch.Response{status: status, headers: headers}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch),
         :ok <- verify_size(headers, attachment.byte_size),
         :ok <- verify_checksum(headers, attachment.checksum_sha256) do
      :ok
    else
      {:ok, %Finch.Response{status: 404}} -> {:error, :object_not_found}
      {:ok, %Finch.Response{status: status}} -> {:error, {:object_storage_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :object_verification_failed}
    end
  end

  defp presign(method, object_key, endpoint \\ :public, request_headers \\ %{}) do
    config = Application.get_env(:comms_integrations, :s3, [])

    with {:ok, scheme} <- endpoint_value(config, endpoint, :scheme),
         {:ok, host} <- endpoint_value(config, endpoint, :host),
         {:ok, port} <- endpoint_value(config, endpoint, :port),
         {:ok, bucket} <- required(config, :bucket),
         {:ok, region} <- required(config, :region),
         {:ok, access_key} <- required(config, :access_key_id),
         {:ok, secret_key} <- required(config, :secret_access_key) do
      expires_in = config |> Keyword.get(:expires_in, 900) |> min(3_600) |> max(60)
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

      query = [
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

      {:ok, %{method: method, url: url, headers: request_headers, expires_in: expires_in}}
    end
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
  defp encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

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

  defp verify_size(headers, expected) do
    actual =
      headers
      |> Enum.find_value(fn {name, value} ->
        if String.downcase(name) == "content-length", do: value
      end)
      |> parse_integer()

    if actual == expected, do: :ok, else: {:error, :object_size_mismatch}
  end

  defp verify_checksum(_headers, nil), do: :ok

  defp verify_checksum(headers, expected) do
    actual = header(headers, "x-amz-meta-sha256")
    if actual == expected, do: :ok, else: {:error, :object_checksum_mismatch}
  end

  defp header(headers, expected_name) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == expected_name, do: value
    end)
  end

  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp hmac(key, value), do: :crypto.mac(:hmac, :sha256, key, value)
end
