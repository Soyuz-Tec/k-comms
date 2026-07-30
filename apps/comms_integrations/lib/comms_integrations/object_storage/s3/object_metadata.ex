defmodule CommsIntegrations.ObjectStorage.S3.ObjectMetadata do
  @moduledoc false

  @server_side_encryption "AES256"
  @variant_content_types ["image/webp", "image/jpeg", "image/png"]

  def server_side_encryption, do: @server_side_encryption

  def required_variant_key(variant) do
    case value(variant, :object_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :variant_object_key_unavailable}
    end
  end

  def required_variant_content_type(variant) do
    case value(variant, :content_type) do
      type when type in @variant_content_types -> {:ok, type}
      _ -> {:error, :unsupported_variant_content_type}
    end
  end

  def required_variant_checksum(variant) do
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

  def required_variant_size(variant) do
    case value(variant, :byte_size) do
      size when is_integer(size) and size > 0 -> {:ok, size}
      _ -> {:error, :variant_size_required}
    end
  end

  def required_variant_version(variant) do
    case value(variant, :object_version_id) do
      version when is_binary(version) and version not in ["", "null"] -> {:ok, version}
      _ -> {:error, :variant_version_unavailable}
    end
  end

  def verify_size(headers, expected) do
    actual =
      headers
      |> Enum.find_value(fn {name, value} ->
        if String.downcase(name) == "content-length", do: value
      end)
      |> parse_integer()

    if actual == expected, do: :ok, else: {:error, :object_size_mismatch}
  end

  def verify_checksum(headers, expected) do
    metadata = header(headers, "x-amz-meta-sha256")
    actual = header(headers, "x-amz-checksum-sha256")

    if metadata == expected and actual == checksum_base64(expected),
      do: :ok,
      else: {:error, :object_checksum_mismatch}
  end

  def verify_encryption(headers) do
    case header(headers, "x-amz-server-side-encryption") do
      algorithm when is_binary(algorithm) and algorithm != "" -> :ok
      _ -> {:error, :object_encryption_missing}
    end
  end

  def verify_stream_status(status) when status in 200..299, do: :ok
  def verify_stream_status(nil), do: {:error, :object_verification_failed}
  def verify_stream_status(status), do: {:error, {:object_storage_status, status}}

  def verify_stream_size(size, expected) when size == expected, do: :ok
  def verify_stream_size(_size, _expected), do: {:error, :object_size_mismatch}

  def verify_stream_version(headers, expected) do
    case response_version(headers) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :object_version_changed_during_verification}
      {:error, _} = error -> error
    end
  end

  def verify_stream_etag(headers, expected) do
    with {:ok, actual} <- response_etag(headers),
         {:ok, normalized_expected} <- normalize_etag(expected),
         {:ok, normalized_actual} <- normalize_etag(actual) do
      if normalized_actual == normalized_expected,
        do: :ok,
        else: {:error, :object_etag_changed_during_verification}
    end
  end

  def verify_stream_checksum(actual, expected) do
    if Base.encode16(actual, case: :lower) == expected,
      do: :ok,
      else: {:error, :object_checksum_mismatch}
  end

  def verify_restore_etag(expected, actual, headers) do
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

  def normalize_etag(etag) when is_binary(etag) do
    normalized = etag |> String.trim() |> String.trim("\"") |> String.downcase()

    if normalized == "",
      do: {:error, :object_etag_unavailable},
      else: {:ok, normalized}
  end

  def normalize_etag(_etag), do: {:error, :object_etag_unavailable}

  def response_version(headers) do
    case header(headers, "x-amz-version-id") do
      version when is_binary(version) and version not in ["", "null"] -> {:ok, version}
      _ -> {:error, :object_versioning_required}
    end
  end

  def response_etag(headers) do
    case header(headers, "etag") do
      etag when is_binary(etag) and etag != "" -> {:ok, String.slice(etag, 0, 255)}
      _ -> {:error, :object_etag_unavailable}
    end
  end

  def required_checksum(attachment) do
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

  def required_verified_checksum(attachment) do
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

  def required_size(attachment) do
    case value(attachment, :byte_size) do
      size when is_integer(size) and size > 0 -> {:ok, size}
      _ -> {:error, :object_size_required}
    end
  end

  def required_etag(attachment) do
    case value(attachment, :object_etag) do
      etag when is_binary(etag) and etag != "" -> {:ok, etag}
      _ -> {:error, :object_etag_unavailable}
    end
  end

  def required_version(attachment) do
    case value(attachment, :object_version_id) do
      version when is_binary(version) and version not in ["", "null"] -> {:ok, version}
      _ -> {:error, :object_version_unavailable}
    end
  end

  def version_query(version) when is_binary(version) and version not in ["", "null"],
    do: [{"versionId", version}]

  def checksum_base64(checksum) do
    {:ok, bytes} = Base.decode16(checksum, case: :mixed)
    Base.encode64(bytes)
  end

  def header(headers, expected_name) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == expected_name, do: value
    end)
  end

  def value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp trustworthy_etag?(expected, actual, headers) do
    algorithm = header(headers, "x-amz-server-side-encryption")

    md5_preserving_encryption?(algorithm) and
      Regex.match?(~r/^[a-f0-9]{32}$/, expected) and
      Regex.match?(~r/^[a-f0-9]{32}$/, actual)
  end

  defp md5_preserving_encryption?(nil), do: true
  defp md5_preserving_encryption?(@server_side_encryption), do: true
  defp md5_preserving_encryption?(_algorithm), do: false

  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end
end
