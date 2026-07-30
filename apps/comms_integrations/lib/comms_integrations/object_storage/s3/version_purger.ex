defmodule CommsIntegrations.ObjectStorage.S3.VersionPurger do
  @moduledoc false

  alias CommsIntegrations.ObjectStorage
  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner, VersionListing}

  @version_page_size 100
  @max_purge_passes 10
  @max_version_listing_bytes 262_144

  def delete_object(request) do
    with :ok <- ObjectStorage.validate_object_request(request),
         {:ok, version} <- ObjectMetadata.required_version(request),
         :ok <- delete_listed_version(ObjectMetadata.value(request, :object_key), version) do
      :ok
    end
  end

  def purge_object_versions(request) do
    with :ok <- ObjectStorage.validate_object_request(request) do
      purge_version_pages(
        ObjectMetadata.value(request, :object_key),
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
end
