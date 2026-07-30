defmodule CommsIntegrations.ObjectStorage.S3.RestoreVerifier do
  @moduledoc false

  alias CommsIntegrations.ObjectStorage
  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner}

  def verify_restored_object(attachment) do
    with :ok <- ObjectStorage.validate_object_request(attachment),
         {:ok, expected_size} <- ObjectMetadata.required_size(attachment),
         {:ok, expected_checksum} <- ObjectMetadata.required_verified_checksum(attachment),
         {:ok, expected_etag} <- ObjectMetadata.required_etag(attachment),
         {:ok, headers} <- head_current_object(attachment),
         :ok <- ObjectMetadata.verify_size(headers, expected_size),
         :ok <- ObjectMetadata.verify_encryption(headers),
         {:ok, version} <- ObjectMetadata.response_version(headers),
         {:ok, restored_etag} <- ObjectMetadata.response_etag(headers),
         {:ok, etag_verification} <-
           ObjectMetadata.verify_restore_etag(expected_etag, restored_etag, headers),
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

  defp head_current_object(attachment) do
    checksum_headers = %{"x-amz-checksum-mode" => "ENABLED"}

    with {:ok, %{url: url, headers: request_headers}} <-
           Presigner.presign(
             "HEAD",
             ObjectMetadata.value(attachment, :object_key),
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
             ObjectMetadata.value(attachment, :object_key),
             :internal,
             %{},
             ObjectMetadata.version_query(version)
           ),
         request <- Finch.build(:get, url, Map.to_list(request_headers)),
         {:ok, result} <- stream_checksum(request, expected_size),
         :ok <- ObjectMetadata.verify_stream_status(result.status),
         :ok <- ObjectMetadata.verify_stream_size(result.bytes, expected_size),
         :ok <- ObjectMetadata.verify_stream_version(result.headers, version),
         :ok <- ObjectMetadata.verify_stream_etag(result.headers, expected_etag),
         :ok <- ObjectMetadata.verify_stream_checksum(result.hash, expected_checksum) do
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
end
