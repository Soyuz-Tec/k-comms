defmodule CommsIntegrations.MeetingArtifacts.SourceMedia do
  @moduledoc false

  alias CommsCore.AudioCalls.ArtifactStorageObject
  alias CommsIntegrations.MeetingArtifacts.Config
  alias CommsIntegrations.ObjectStorage
  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner}

  def fetch(%ArtifactStorageObject{} = object, config) do
    with :ok <- ObjectStorage.validate_object_request(object),
         {:ok, _} <- Config.storage_configuration(),
         {:ok, size} <- ObjectMetadata.required_size(object),
         true <- size <= config.max_media_bytes,
         {:ok, checksum} <- ObjectMetadata.required_verified_checksum(object),
         {:ok, version} <- ObjectMetadata.required_version(object),
         {:ok, descriptor} <-
           Presigner.presign("GET", object.object_key, :internal, %{}, [{"versionId", version}]),
         {:ok, result} <-
           stream(Finch.build(:get, descriptor.url), size, config.timeout_ms),
         :ok <- ObjectMetadata.verify_stream_status(result.status),
         :ok <- ObjectMetadata.verify_stream_size(result.bytes, size),
         :ok <- ObjectMetadata.verify_stream_version(result.headers, version),
         :ok <- ObjectMetadata.verify_stream_checksum(result.hash, checksum),
         :ok <- verify_etag(object.object_etag, result.headers) do
      {:ok, IO.iodata_to_binary(result.chunks)}
    else
      {:error, _} = error -> error
      _ -> {:error, :artifact_source_media_unavailable}
    end
  end

  def fetch(_, _), do: {:error, :artifact_source_media_unavailable}

  defp stream(request, expected_size, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    initial = %{
      status: nil,
      bytes: 0,
      headers: [],
      hash: :crypto.hash_init(:sha256),
      chunks: [],
      error: nil
    }

    Finch.stream_while(
      request,
      CommsIntegrations.Finch,
      initial,
      fn event, acc ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, %{acc | error: :artifact_source_media_timeout}}
        else
          consume(event, acc, expected_size)
        end
      end,
      pool_timeout: min(timeout_ms, 1_000),
      receive_timeout: min(timeout_ms, 5_000),
      request_timeout: timeout_ms
    )
    |> case do
      {:ok, %{error: nil} = result} -> {:ok, %{result | hash: :crypto.hash_final(result.hash)}}
      _ -> {:error, :artifact_source_media_unavailable}
    end
  rescue
    _ -> {:error, :artifact_source_media_unavailable}
  catch
    :exit, _ -> {:error, :artifact_source_media_unavailable}
  end

  defp consume({:status, status}, acc, _) when status in 200..299,
    do: {:cont, %{acc | status: status}}

  defp consume({:status, _}, acc, _),
    do: {:halt, %{acc | error: :artifact_source_media_unavailable}}

  defp consume({kind, headers}, acc, _) when kind in [:headers, :trailers],
    do: {:cont, %{acc | headers: acc.headers ++ headers}}

  defp consume({:data, data}, acc, expected_size) do
    bytes = acc.bytes + byte_size(data)

    if bytes <= expected_size do
      {:cont,
       %{
         acc
         | bytes: bytes,
           hash: :crypto.hash_update(acc.hash, data),
           chunks: [acc.chunks, data]
       }}
    else
      {:halt, %{acc | error: :object_size_mismatch}}
    end
  end

  defp verify_etag(nil, _), do: :ok
  defp verify_etag(etag, headers), do: ObjectMetadata.verify_stream_etag(headers, etag)
end
