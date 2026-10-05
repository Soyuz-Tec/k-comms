defmodule CommsIntegrations.MeetingArtifacts.S3Storage do
  @moduledoc "Version-pinned artifact verification and access within the existing approved S3 bucket."
  @behaviour CommsCore.AudioCalls.ArtifactStoragePort.Contract

  alias CommsCore.AudioCalls.ArtifactStorageObject
  alias CommsIntegrations.MeetingArtifacts.Config
  alias CommsIntegrations.ObjectStorage
  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner}

  @timeout_ms 5_000

  def configured?(), do: match?({:ok, _}, Config.storage_configuration())
  def authorized_adapter?(caller), do: caller == __MODULE__

  def verify(object, requester \\ &request/1)

  def verify(%ArtifactStorageObject{} = object, requester) when is_function(requester, 1) do
    with :ok <- validate(object),
         {:ok, _} <- Config.storage_configuration(),
         {:ok, expected_size} <- ObjectMetadata.required_size(object),
         :ok <- validate_optional_pins(object),
         {:ok, headers} <- head(object, object.object_version_id, requester),
         {:ok, observed} <- verified_metadata(headers, object, expected_size),
         :ok <- confirm_version_pin(object, observed, expected_size, requester) do
      {:ok,
       %ArtifactStorageObject{
         object
         | object_version_id: observed.version,
           checksum_sha256: observed.checksum,
           verified_checksum_sha256: observed.checksum,
           object_etag: observed.etag
       }}
    end
  end

  def verify(_, _), do: {:error, :invalid_artifact_storage_object}

  def download(%ArtifactStorageObject{} = object) do
    with :ok <- validate(object),
         {:ok, _} <- Config.storage_configuration(),
         {:ok, version} <- ObjectMetadata.required_version(object),
         {:ok, _} <- ObjectMetadata.required_verified_checksum(object),
         {:ok, _} <- ObjectMetadata.required_size(object) do
      Presigner.presign(
        "GET",
        object.object_key,
        :public,
        %{},
        [
          {"versionId", version},
          {"response-content-type", "application/octet-stream"},
          {"response-content-disposition", "attachment"}
        ],
        :download
      )
    end
  end

  def download(_), do: {:error, :invalid_artifact_storage_object}

  # Artifact keys are unique to the server-owned capture. Erasure must remove
  # every overwritten or partial version at that exact key, including keys
  # whose provider failed before reporting a final version.
  def delete(object, purger \\ &ObjectStorage.purge_object_versions/1)

  def delete(%ArtifactStorageObject{} = object, purger) when is_function(purger, 1) do
    with :ok <- validate(object),
         {:ok, _} <- Config.storage_configuration(),
         {:ok, %{verified_empty?: true}} <-
           purger.(%{tenant_id: object.tenant_id, object_key: object.object_key}) do
      :ok
    else
      {:ok, _} -> {:error, :artifact_object_deletion_not_verified}
      {:error, _} = error -> error
      _ -> {:error, :artifact_object_deletion_failed}
    end
  rescue
    _ -> {:error, :artifact_storage_unavailable}
  catch
    :exit, _ -> {:error, :artifact_storage_unavailable}
  end

  def delete(_, _), do: {:error, :invalid_artifact_storage_object}

  defp validate(object) do
    with true <- is_binary(object.tenant_id) and valid_segment?(object.tenant_id),
         true <- is_binary(object.object_key) and object.content_type == "video/mp4",
         [tenant, "meeting-artifacts", call_id, filename] <- String.split(object.object_key, "/"),
         true <- tenant == object.tenant_id and valid_segment?(call_id),
         true <- String.ends_with?(filename, ".mp4") and valid_segment?(filename),
         :ok <- ObjectStorage.validate_object_request(object) do
      :ok
    else
      _ -> {:error, :invalid_artifact_storage_object}
    end
  end

  defp validate_optional_pins(object) do
    with true <-
           is_nil(object.object_version_id) or
             match?({:ok, _}, ObjectMetadata.required_version(object)),
         true <-
           is_nil(object.checksum_sha256) or
             match?({:ok, _}, ObjectMetadata.required_checksum(object)) do
      :ok
    else
      _ -> {:error, :invalid_artifact_storage_object}
    end
  end

  defp confirm_version_pin(
         %ArtifactStorageObject{object_version_id: nil} = object,
         observed,
         expected_size,
         requester
       ) do
    pinned = %ArtifactStorageObject{
      object
      | object_version_id: observed.version,
        checksum_sha256: observed.checksum,
        object_etag: observed.etag
    }

    with {:ok, headers} <- head(pinned, observed.version, requester),
         {:ok, _} <- verified_metadata(headers, pinned, expected_size) do
      :ok
    end
  end

  defp confirm_version_pin(_, _, _, _), do: :ok

  defp verified_metadata(headers, object, expected_size) do
    with :ok <- ObjectMetadata.verify_size(headers, expected_size),
         {:ok, version} <- ObjectMetadata.response_version(headers),
         true <- is_nil(object.object_version_id) or version == object.object_version_id,
         true <-
           unique_header(headers, "x-amz-server-side-encryption") in [
             "AES256",
             "aws:kms",
             "aws:kms:dsse"
           ],
         {:ok, checksum} <- full_object_checksum(headers),
         true <-
           is_nil(object.checksum_sha256) or checksum == String.downcase(object.checksum_sha256),
         true <- unique_header(headers, "x-amz-meta-sha256") in [nil, checksum],
         {:ok, etag} <- ObjectMetadata.response_etag(headers),
         :ok <- verify_etag(object.object_etag, etag) do
      {:ok, %{version: version, checksum: checksum, etag: etag}}
    else
      {:error, _} = error -> error
      _ -> {:error, :artifact_object_verification_failed}
    end
  end

  # Multipart composite checksums are not the SHA256 of the object's bytes.
  # Do not treat an ETag, user metadata, or a provider URL as integrity evidence.
  defp full_object_checksum(headers) do
    with true <- unique_header(headers, "x-amz-checksum-type") in [nil, "FULL_OBJECT"],
         checksum when is_binary(checksum) <- unique_header(headers, "x-amz-checksum-sha256"),
         {:ok, bytes} when byte_size(bytes) == 32 <- Base.decode64(checksum) do
      {:ok, Base.encode16(bytes, case: :lower)}
    else
      _ -> {:error, :artifact_object_checksum_unavailable}
    end
  end

  defp verify_etag(nil, _), do: :ok

  defp verify_etag(expected, actual) do
    with {:ok, normalized_expected} <- ObjectMetadata.normalize_etag(expected),
         {:ok, ^normalized_expected} <- ObjectMetadata.normalize_etag(actual) do
      :ok
    else
      _ -> {:error, :object_etag_changed_during_verification}
    end
  end

  defp head(object, version, requester) do
    query = if is_nil(version), do: [], else: [{"versionId", version}]

    with {:ok, descriptor} <-
           Presigner.presign(
             "HEAD",
             object.object_key,
             :internal,
             %{"x-amz-checksum-mode" => "ENABLED"},
             query
           ),
         {:ok, response} <-
           requester.(Finch.build(:head, descriptor.url, Map.to_list(descriptor.headers))) do
      case response do
        %{status: status, headers: headers} when status in 200..299 and is_list(headers) ->
          {:ok, headers}

        %{status: 404} ->
          {:error, :object_not_found}

        _ ->
          {:error, :artifact_storage_unavailable}
      end
    else
      _ -> {:error, :artifact_storage_unavailable}
    end
  end

  defp request(request) do
    Finch.request(request, CommsIntegrations.Finch,
      pool_timeout: 1_000,
      request_timeout: @timeout_ms,
      receive_timeout: @timeout_ms
    )
  rescue
    _ -> {:error, :artifact_storage_unavailable}
  catch
    :exit, _ -> {:error, :artifact_storage_unavailable}
  end

  defp unique_header(headers, name) do
    case Enum.filter(headers, fn {key, _} -> String.downcase(key) == name end) do
      [{_, value}] -> value
      [] -> nil
      _ -> :ambiguous_header
    end
  end

  defp valid_segment?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,254}$/, value)
end
