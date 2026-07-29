defmodule CommsIntegrations.ObjectStorage.S3 do
  @behaviour CommsIntegrations.ObjectStorage

  alias CommsIntegrations.ObjectStorage.S3.{EndpointPolicy, Presigner, VersionListing}

  @server_side_encryption "AES256"
  # Mirrors the database constraint. SVG is excluded because a variant is served
  # inline and SVG is scriptable.
  @variant_content_types ["image/webp", "image/jpeg", "image/png"]
  @version_page_size 100
  @max_purge_passes 10
  @max_version_listing_bytes 262_144

  @impl true
  def presign_upload(attachment) do
    with {:ok, checksum} <- required_checksum(attachment) do
      headers = %{
        "content-type" => attachment.content_type,
        "x-amz-checksum-sha256" => checksum_base64(checksum),
        "x-amz-meta-sha256" => checksum,
        "x-amz-server-side-encryption" => @server_side_encryption
      }

      Presigner.presign("PUT", attachment.object_key, :public, headers, [])
    end
  end

  @impl true
  def presign_download(attachment) do
    with {:ok, version} <- required_version(attachment) do
      Presigner.presign(
        "GET",
        attachment.object_key,
        :public,
        %{},
        [{"versionId", version}] ++ download_response_overrides(attachment),
        :download
      )
    end
  end

  # A presigned GET is a bearer capability for whatever the object contains, and
  # the permitted content types include `text/*`. Without these overrides the
  # object store would serve that content inline, executing it on the
  # object-store origin. Forcing an opaque type and attachment disposition makes
  # every download a download. Both are signed, so neither can be stripped.
  defp download_response_overrides(attachment) do
    [
      {"response-content-type", "application/octet-stream"},
      {"response-content-disposition", content_disposition(value(attachment, :file_name))}
    ]
  end

  defp content_disposition(file_name) when is_binary(file_name) do
    case sanitized_filename(file_name) do
      "" -> "attachment"
      safe -> "attachment; filename*=UTF-8''#{Presigner.encode(safe)}"
    end
  end

  defp content_disposition(_file_name), do: "attachment"

  # Control characters and path separators are removed so the recorded name can
  # never redirect the write or break out of the header. The value is
  # percent-encoded for RFC 5987, so the remaining characters are inert.
  defp sanitized_filename(file_name) do
    file_name
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
    |> String.replace(~r{[/\\]}, "_")
    |> String.trim()
    |> String.slice(0, 200)
  end

  @impl true
  def presign_variant_upload(variant) do
    with {:ok, key} <- required_variant_key(variant),
         {:ok, content_type} <- required_variant_content_type(variant),
         {:ok, checksum} <- required_variant_checksum(variant) do
      # The content type is signed, so the object store rejects an upload that
      # declares anything else. That is what keeps a variant -- the one
      # attachment surface served inline -- from being stored as an executable
      # type regardless of what the client sends.
      headers = %{
        "content-type" => content_type,
        "x-amz-checksum-sha256" => checksum_base64(checksum),
        "x-amz-meta-sha256" => checksum,
        "x-amz-server-side-encryption" => @server_side_encryption
      }

      Presigner.presign("PUT", key, :public, headers, [])
    end
  end

  @impl true
  def presign_variant_download(variant) do
    with {:ok, key} <- required_variant_key(variant),
         {:ok, content_type} <- required_variant_content_type(variant),
         {:ok, version} <- required_variant_version(variant) do
      # Inline is the deliberate exception to the attachment disposition forced
      # on ordinary downloads, and it is safe only because the type is pinned to
      # a non-executable raster format both here and at upload.
      Presigner.presign(
        "GET",
        key,
        :public,
        %{},
        [
          {"versionId", version},
          {"response-content-type", content_type},
          {"response-content-disposition", "inline"}
        ],
        :download
      )
    end
  end

  @impl true
  def verify_variant_upload(variant) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, key} <- required_variant_key(variant),
         {:ok, checksum} <- required_variant_checksum(variant),
         {:ok, expected_size} <- required_variant_size(variant),
         {:ok, %{url: url, headers: request_headers}} <-
           Presigner.presign("HEAD", key, :internal, checksum_headers, []),
         request <- Finch.build(:head, url, Map.to_list(request_headers)),
         {:ok, %Finch.Response{status: status, headers: headers}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch),
         :ok <- verify_size(headers, expected_size),
         :ok <- verify_checksum(headers, checksum),
         :ok <- verify_encryption(headers),
         {:ok, version} <- response_version(headers) do
      {:ok, %{object_version_id: version}}
    else
      {:ok, %Finch.Response{status: 404}} -> {:error, :object_not_found}
      {:ok, %Finch.Response{status: status}} -> {:error, {:object_storage_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :object_verification_failed}
    end
  end

  defp required_variant_key(variant) do
    case value(variant, :object_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :variant_object_key_unavailable}
    end
  end

  defp required_variant_content_type(variant) do
    case value(variant, :content_type) do
      type when type in @variant_content_types -> {:ok, type}
      _ -> {:error, :unsupported_variant_content_type}
    end
  end

  defp required_variant_checksum(variant) do
    case value(variant, :checksum_sha256) do
      checksum when is_binary(checksum) ->
        checksum = String.downcase(checksum)

        if Regex.match?(~r/^[a-f0-9]{64}$/, checksum),
          do: {:ok, checksum},
          else: {:error, :variant_checksum_required}

      _ ->
        {:error, :variant_checksum_required}
    end
  end

  defp required_variant_size(variant) do
    case value(variant, :byte_size) do
      size when is_integer(size) and size > 0 -> {:ok, size}
      _ -> {:error, :variant_size_required}
    end
  end

  defp required_variant_version(variant) do
    case value(variant, :object_version_id) do
      version when is_binary(version) and version not in ["", "null"] -> {:ok, version}
      _ -> {:error, :variant_version_unavailable}
    end
  end

  @impl true
  def verify_upload(attachment) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, %{url: url, headers: request_headers}} <-
           Presigner.presign("HEAD", attachment.object_key, :internal, checksum_headers, []),
         request <- Finch.build(:head, url, Map.to_list(request_headers)),
         {:ok, %Finch.Response{status: status, headers: headers}} when status in 200..299 <-
           Finch.request(request, CommsIntegrations.Finch),
         :ok <- verify_size(headers, attachment.byte_size),
         {:ok, checksum} <- required_checksum(attachment),
         :ok <- verify_checksum(headers, checksum),
         :ok <- verify_encryption(headers),
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
         :ok <- verify_encryption(headers),
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
         :ok <- delete_listed_version(value(request, :object_key), version) do
      :ok
    end
  end

  @impl true
  def purge_object_versions(request) do
    with :ok <- CommsIntegrations.ObjectStorage.validate_object_request(request) do
      purge_version_pages(
        value(request, :object_key),
        @max_purge_passes,
        %{deleted_versions: 0, deleted_markers: 0}
      )
    end
  end

  defp purge_version_pages(object_key, remaining, counts) when remaining > 0 do
    with {:ok, listing} <- list_exact_versions(object_key),
         :ok <- delete_listed_versions(object_key, listing.entries) do
      counts = count_deleted(counts, listing.entries)

      cond do
        listing.entries == [] ->
          {:ok, Map.put(counts, :verified_empty?, true)}

        remaining == 1 ->
          with {:ok, verification} <- list_exact_versions(object_key) do
            {:ok, Map.put(counts, :verified_empty?, verification.entries == [])}
          end

        true ->
          purge_version_pages(object_key, remaining - 1, counts)
      end
    end
  end

  defp list_exact_versions(object_key) do
    query = [
      {"versions", ""},
      {"prefix", object_key},
      {"max-keys", Integer.to_string(@version_page_size)}
    ]

    with {:ok, %{url: url}} <- Presigner.presign("GET", "", :internal, %{}, query),
         request <- Finch.build(:get, url),
         {:ok, body} <- stream_bounded_body(request, @max_version_listing_bytes),
         {:ok, listing} <- VersionListing.parse(body) do
      entries = Enum.filter(listing.entries, &(&1.key == object_key))
      {:ok, %{listing | entries: entries}}
    end
  end

  defp delete_listed_versions(object_key, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case delete_listed_version(object_key, entry.version_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_listed_version(object_key, version)
       when is_binary(object_key) and is_binary(version) and version != "" do
    with {:ok, %{url: url}} <-
           Presigner.presign("DELETE", object_key, :internal, %{}, [{"versionId", version}]),
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

  defp delete_listed_version(_object_key, _version),
    do: {:error, :object_version_listing_invalid}

  defp count_deleted(counts, entries) do
    Enum.reduce(entries, counts, fn
      %{kind: :version}, acc ->
        Map.update!(acc, :deleted_versions, &(&1 + 1))

      %{kind: :delete_marker}, acc ->
        Map.update!(acc, :deleted_markers, &(&1 + 1))
    end)
  end

  defp stream_bounded_body(request, max_bytes) do
    initial = %{status: nil, bytes: 0, chunks: [], error: nil}

    Finch.stream_while(
      request,
      CommsIntegrations.Finch,
      initial,
      fn
        {:status, status}, acc when status in 200..299 ->
          {:cont, %{acc | status: status}}

        {:status, status}, acc ->
          {:halt, %{acc | status: status, error: {:object_storage_status, status}}}

        {:headers, _headers}, acc ->
          {:cont, acc}

        {:data, data}, acc ->
          bytes = acc.bytes + byte_size(data)

          if bytes <= max_bytes do
            {:cont, %{acc | bytes: bytes, chunks: [acc.chunks, data]}}
          else
            {:halt, %{acc | bytes: bytes, error: :object_version_listing_too_large}}
          end

        {:trailers, _headers}, acc ->
          {:cont, acc}
      end,
      receive_timeout: 30_000
    )
    |> case do
      {:ok, %{error: nil, status: status, chunks: chunks}} when status in 200..299 ->
        {:ok, IO.iodata_to_binary(chunks)}

      {:ok, %{error: error}} when not is_nil(error) ->
        {:error, error}

      {:error, _reason} ->
        {:error, :object_storage_unavailable}

      _ ->
        {:error, :object_version_listing_failed}
    end
  rescue
    _ -> {:error, :object_storage_unavailable}
  end

  @impl true
  def status, do: EndpointPolicy.status()

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

  # The object must come back reporting a server-side encryption algorithm.
  # Any algorithm is accepted so a KMS-backed bucket is not rejected for being
  # stronger than the requested default; an unencrypted object fails closed.
  defp verify_encryption(headers) do
    case header(headers, "x-amz-server-side-encryption") do
      algorithm when is_binary(algorithm) and algorithm != "" -> :ok
      _ -> {:error, :object_encryption_missing}
    end
  end

  defp head_current_object(attachment) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, %{url: url, headers: request_headers}} <-
           Presigner.presign(
             "HEAD",
             value(attachment, :object_key),
             :internal,
             checksum_headers,
             []
           ),
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
           Presigner.presign(
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
    algorithm = header(headers, "x-amz-server-side-encryption")

    md5_preserving_encryption?(algorithm) and
      Regex.match?(~r/^[a-f0-9]{32}$/, expected) and
      Regex.match?(~r/^[a-f0-9]{32}$/, actual)
  end

  # SSE-S3 keeps the ETag equal to the plaintext MD5 for single-part uploads, so
  # the ETag stays usable as a cheap cross-check under the requested default.
  # KMS and customer-provided keys do not, and their opaque ETags are never
  # treated as content evidence. The streamed SHA-256 remains authoritative in
  # every case.
  defp md5_preserving_encryption?(nil), do: true
  defp md5_preserving_encryption?(@server_side_encryption), do: true
  defp md5_preserving_encryption?(_algorithm), do: false

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

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
