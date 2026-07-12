defmodule CommsIntegrations.ObjectStorage.S3 do
  @behaviour CommsIntegrations.ObjectStorage

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"

  @impl true
  def presign_upload(attachment) do
    with {:ok, checksum} <- required_checksum(attachment) do
      headers = %{
        "content-type" => attachment.content_type,
        "x-amz-checksum-sha256" => checksum_base64(checksum),
        "x-amz-meta-sha256" => checksum
      }

      presign("PUT", attachment.object_key, :public, headers, [])
    end
  end

  @impl true
  def presign_download(attachment) do
    with {:ok, version} <- required_version(attachment) do
      presign("GET", attachment.object_key, :public, %{}, [{"versionId", version}])
    end
  end

  @impl true
  def verify_upload(attachment) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, %{url: url, headers: request_headers}} <-
           presign("HEAD", attachment.object_key, :internal, checksum_headers, []),
         request <- Finch.build(:head, url, Map.to_list(request_headers)),
         {:ok, %Finch.Response{status: status, headers: headers}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch),
         :ok <- verify_size(headers, attachment.byte_size),
         {:ok, checksum} <- required_checksum(attachment),
         :ok <- verify_checksum(headers, checksum),
         {:ok, version} <- response_version(headers),
         {:ok, etag} <- response_etag(headers) do
      {:ok,
       %{
         object_version_id: version,
         object_etag: etag,
         verified_checksum_sha256: checksum
       }}
    else
      {:ok, %Finch.Response{status: 404}} -> {:error, :object_not_found}
      {:ok, %Finch.Response{status: status}} -> {:error, {:object_storage_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :object_verification_failed}
    end
  end

  @impl true
  def verify_restored_object(attachment) do
    with :ok <- CommsIntegrations.ObjectStorage.validate_object_request(attachment),
         {:ok, expected_size} <- required_size(attachment),
         {:ok, expected_checksum} <- required_verified_checksum(attachment),
         {:ok, expected_etag} <- required_etag(attachment),
         {:ok, headers} <- head_current_object(attachment),
         :ok <- verify_size(headers, expected_size),
         {:ok, version} <- response_version(headers),
         {:ok, restored_etag} <- response_etag(headers),
         {:ok, etag_verification} <-
           verify_restore_etag(expected_etag, restored_etag, headers),
         :ok <-
           verify_restored_body(
             attachment,
             version,
             restored_etag,
             expected_size,
             expected_checksum
           ) do
      {:ok,
       %{
         object_version_id: version,
         object_etag: restored_etag,
         verified_checksum_sha256: expected_checksum,
         etag_verification: etag_verification
       }}
    end
  end

  @impl true
  def delete_object(request) do
    with :ok <- CommsIntegrations.ObjectStorage.validate_object_request(request),
         {:ok, version} <- required_version(request),
         query <- version_query(version),
         {:ok, %{url: url}} <-
           presign("DELETE", value(request, :object_key), :internal, %{}, query),
         http_request <- Finch.build(:delete, url),
         {:ok, %Finch.Response{status: status}} when status in 200..299 or status == 404 <-
           Finch.request(http_request, CommsIntegrations.Finch) do
      :ok
    else
      {:ok, %Finch.Response{status: status}} -> {:error, {:object_storage_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :object_deletion_failed}
    end
  end

  @impl true
  def status do
    config = Application.get_env(:comms_integrations, :s3, [])
    required = [:scheme, :host, :port, :bucket, :region, :access_key_id, :secret_access_key]
    missing = Enum.filter(required, &(Keyword.get(config, &1) in [nil, ""]))

    cond do
      missing != [] ->
        %{status: :unavailable, adapter: "s3", reason: :missing_configuration, missing: missing}

      public_endpoint_allowed?(
        Keyword.get(config, :scheme),
        Keyword.get(config, :host),
        Keyword.get(config, :port)
      ) ->
        %{status: :available, adapter: "s3"}

      true ->
        %{status: :unavailable, adapter: "s3", reason: :insecure_public_object_storage_endpoint}
    end
  end

  defp presign(
         method,
         object_key,
         endpoint,
         request_headers,
         extra_query
       ) do
    config = Application.get_env(:comms_integrations, :s3, [])

    with {:ok, scheme} <- endpoint_value(config, endpoint, :scheme),
         {:ok, host} <- endpoint_value(config, endpoint, :host),
         {:ok, port} <- endpoint_value(config, endpoint, :port),
         {:ok, bucket} <- required(config, :bucket),
         {:ok, region} <- required(config, :region),
         {:ok, access_key} <- required(config, :access_key_id),
         {:ok, secret_key} <- required(config, :secret_access_key),
         :ok <- validate_endpoint_security(endpoint, scheme, host, port) do
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
         expires_in: expires_in
       }}
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

  defp validate_endpoint_security(:internal, scheme, _host, _port)
       when scheme in ["http", "https"],
       do: :ok

  defp validate_endpoint_security(:public, scheme, host, port) do
    if public_endpoint_allowed?(scheme, host, port),
      do: :ok,
      else: {:error, :insecure_public_object_storage_endpoint}
  end

  defp validate_endpoint_security(_, _, _, _),
    do: {:error, :invalid_object_storage_endpoint}

  defp public_endpoint_allowed?("https", host, port),
    do: is_binary(host) and host != "" and is_integer(port) and port > 0

  defp public_endpoint_allowed?("http", host, port) do
    Application.get_env(:comms_integrations, :allow_insecure_local_object_storage, false) and
      local_development_host?(host) and is_integer(port) and port > 0
  end

  defp public_endpoint_allowed?(_, _, _), do: false

  defp local_development_host?(host) do
    host in ["localhost", "127.0.0.1", "::1", "minio", "host.containers.internal"]
  end

  defp verify_size(headers, expected) do
    actual =
      headers
      |> Enum.find_value(fn {name, value} ->
        if String.downcase(name) == "content-length", do: value
      end)
      |> parse_integer()

    if actual == expected, do: :ok, else: {:error, :object_size_mismatch}
  end

  defp verify_checksum(headers, expected) do
    metadata = header(headers, "x-amz-meta-sha256")
    actual = header(headers, "x-amz-checksum-sha256")

    if metadata == expected and actual == checksum_base64(expected),
      do: :ok,
      else: {:error, :object_checksum_mismatch}
  end

  defp head_current_object(attachment) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, %{url: url, headers: request_headers}} <-
           presign("HEAD", value(attachment, :object_key), :internal, checksum_headers, []),
         request <- Finch.build(:head, url, Map.to_list(request_headers)) do
      case Finch.request(request, CommsIntegrations.Finch) do
        {:ok, %Finch.Response{status: status, headers: headers}} when status in 200..299 ->
          {:ok, headers}

        {:ok, %Finch.Response{status: 404}} ->
          {:error, :object_not_found}

        {:ok, %Finch.Response{status: status}} ->
          {:error, {:object_storage_status, status}}

        {:error, _reason} ->
          {:error, :object_storage_unavailable}
      end
    end
  rescue
    _ -> {:error, :object_storage_unavailable}
  end

  defp verify_restored_body(
         attachment,
         version,
         expected_etag,
         expected_size,
         expected_checksum
       ) do
    with {:ok, %{url: url, headers: request_headers}} <-
           presign(
             "GET",
             value(attachment, :object_key),
             :internal,
             %{},
             version_query(version)
           ),
         request <- Finch.build(:get, url, Map.to_list(request_headers)),
         {:ok, result} <- stream_checksum(request, expected_size),
         :ok <- verify_stream_status(result.status),
         :ok <- verify_stream_size(result.bytes, expected_size),
         :ok <- verify_stream_version(result.headers, version),
         :ok <- verify_stream_etag(result.headers, expected_etag),
         :ok <- verify_stream_checksum(result.hash, expected_checksum) do
      :ok
    end
  end

  defp stream_checksum(request, expected_size) do
    initial = %{
      status: nil,
      headers: [],
      bytes: 0,
      hash: :crypto.hash_init(:sha256),
      error: nil
    }

    Finch.stream_while(
      request,
      CommsIntegrations.Finch,
      initial,
      fn
        {:status, status}, acc when status in 200..299 ->
          {:cont, %{acc | status: status}}

        {:status, status}, acc ->
          {:halt, %{acc | status: status, error: {:object_storage_status, status}}}

        {:headers, headers}, acc ->
          {:cont, %{acc | headers: acc.headers ++ headers}}

        {:data, data}, acc ->
          bytes = acc.bytes + byte_size(data)

          if bytes <= expected_size do
            {:cont, %{acc | bytes: bytes, hash: :crypto.hash_update(acc.hash, data)}}
          else
            {:halt, %{acc | bytes: bytes, error: :object_size_mismatch}}
          end

        {:trailers, headers}, acc ->
          {:cont, %{acc | headers: acc.headers ++ headers}}
      end,
      receive_timeout: 30_000
    )
    |> case do
      {:ok, %{error: nil} = result} ->
        {:ok, %{result | hash: :crypto.hash_final(result.hash)}}

      {:ok, %{error: error}} ->
        {:error, error}

      {:error, _reason} ->
        {:error, :object_storage_unavailable}
    end
  rescue
    _ -> {:error, :object_storage_unavailable}
  end

  defp verify_stream_status(status) when status in 200..299, do: :ok
  defp verify_stream_status(nil), do: {:error, :object_verification_failed}
  defp verify_stream_status(status), do: {:error, {:object_storage_status, status}}

  defp verify_stream_size(size, expected) when size == expected, do: :ok
  defp verify_stream_size(_size, _expected), do: {:error, :object_size_mismatch}

  defp verify_stream_version(headers, expected) do
    case response_version(headers) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :object_version_changed_during_verification}
      {:error, _} = error -> error
    end
  end

  defp verify_stream_etag(headers, expected) do
    with {:ok, actual} <- response_etag(headers),
         {:ok, normalized_expected} <- normalize_etag(expected),
         {:ok, normalized_actual} <- normalize_etag(actual) do
      if normalized_actual == normalized_expected,
        do: :ok,
        else: {:error, :object_etag_changed_during_verification}
    end
  end

  defp verify_stream_checksum(actual, expected) do
    if Base.encode16(actual, case: :lower) == expected,
      do: :ok,
      else: {:error, :object_checksum_mismatch}
  end

  defp verify_restore_etag(expected, actual, headers) do
    with {:ok, expected} <- normalize_etag(expected),
         {:ok, actual} <- normalize_etag(actual) do
      if trustworthy_etag?(expected, actual, headers) do
        if expected == actual,
          do: {:ok, :matched},
          else: {:error, :object_etag_mismatch}
      else
        {:ok, :not_trustworthy}
      end
    end
  end

  defp trustworthy_etag?(expected, actual, headers) do
    is_nil(header(headers, "x-amz-server-side-encryption")) and
      Regex.match?(~r/^[a-f0-9]{32}$/, expected) and
      Regex.match?(~r/^[a-f0-9]{32}$/, actual)
  end

  defp normalize_etag(etag) when is_binary(etag) do
    normalized = etag |> String.trim() |> String.trim("\"") |> String.downcase()

    if normalized == "",
      do: {:error, :object_etag_unavailable},
      else: {:ok, normalized}
  end

  defp normalize_etag(_etag), do: {:error, :object_etag_unavailable}

  defp response_version(headers) do
    case header(headers, "x-amz-version-id") do
      version when is_binary(version) and version not in ["", "null"] -> {:ok, version}
      _ -> {:error, :object_versioning_required}
    end
  end

  defp response_etag(headers) do
    case header(headers, "etag") do
      etag when is_binary(etag) and etag != "" -> {:ok, String.slice(etag, 0, 255)}
      _ -> {:error, :object_etag_unavailable}
    end
  end

  defp required_checksum(attachment) do
    case value(attachment, :checksum_sha256) do
      checksum when is_binary(checksum) ->
        checksum = String.downcase(checksum)

        if Regex.match?(~r/^[a-f0-9]{64}$/, checksum),
          do: {:ok, checksum},
          else: {:error, :object_checksum_required}

      _ ->
        {:error, :object_checksum_required}
    end
  end

  defp required_verified_checksum(attachment) do
    expected = value(attachment, :checksum_sha256)
    verified = value(attachment, :verified_checksum_sha256)

    with checksum when is_binary(checksum) <- verified,
         checksum <- String.downcase(checksum),
         true <- Regex.match?(~r/^[a-f0-9]{64}$/, checksum),
         expected when is_binary(expected) <- expected,
         true <- String.downcase(expected) == checksum do
      {:ok, checksum}
    else
      _ -> {:error, :verified_object_checksum_required}
    end
  end

  defp required_size(attachment) do
    case value(attachment, :byte_size) do
      size when is_integer(size) and size > 0 -> {:ok, size}
      _ -> {:error, :object_size_required}
    end
  end

  defp required_etag(attachment) do
    case value(attachment, :object_etag) do
      etag when is_binary(etag) and etag != "" -> {:ok, etag}
      _ -> {:error, :object_etag_unavailable}
    end
  end

  defp required_version(attachment) do
    case value(attachment, :object_version_id) do
      version when is_binary(version) and version not in ["", "null"] -> {:ok, version}
      _ -> {:error, :object_version_unavailable}
    end
  end

  defp version_query(version) when is_binary(version) and version not in ["", "null"],
    do: [{"versionId", version}]

  defp checksum_base64(checksum) do
    {:ok, bytes} = Base.decode16(checksum, case: :mixed)
    Base.encode64(bytes)
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
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
