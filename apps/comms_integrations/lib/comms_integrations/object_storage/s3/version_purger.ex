defmodule CommsIntegrations.ObjectStorage.S3.VersionPurger do
  @moduledoc false

  alias CommsIntegrations.ObjectStorage
  alias CommsIntegrations.ObjectStorage.S3.{ObjectMetadata, Presigner, VersionListing}

  @version_page_size 100
  @max_purge_passes 10
  @max_version_listing_bytes 262_144
  @purge_budget_ms 60_000
  @request_budget_ms 30_000

  def delete_object(request) do
    with :ok <- ObjectStorage.validate_object_request(request),
         {:ok, version} <- ObjectMetadata.required_version(request),
         :ok <-
           delete_listed_version(ObjectMetadata.value(request, :object_key), version, context()) do
      :ok
    end
  end

  def purge_object_versions(request),
    do: purge_object_versions(request, &stream_response/3, &monotonic_ms/0)

  # Explicit transport/clock seam for protocol and deadline tests. Production
  # always uses the fixed aggregate budget, never an application override.
  @doc false
  def purge_object_versions(request, requester, clock)
      when is_function(requester, 3) and is_function(clock, 0) do
    with :ok <- ObjectStorage.validate_object_request(request) do
      purge_version_pages(
        ObjectMetadata.value(request, :object_key),
        @max_purge_passes,
        %{deleted_versions: 0, deleted_markers: 0},
        context(requester, clock)
      )
    end
  end

  defp context(requester \\ &stream_response/3, clock \\ &monotonic_ms/0),
    do: %{requester: requester, clock: clock, deadline: clock.() + @purge_budget_ms}

  defp purge_version_pages(object_key, remaining, counts, context) when remaining > 0 do
    with {:ok, listing} <- list_exact_versions(object_key, context),
         :ok <- delete_listed_versions(object_key, listing.entries, context),
         :ok <- before_deadline(context) do
      counts = count_deleted(counts, listing.entries)

      cond do
        listing.entries == [] ->
          {:ok, Map.put(counts, :verified_empty?, true)}

        remaining == 1 ->
          with {:ok, verification} <- list_exact_versions(object_key, context),
               :ok <- before_deadline(context) do
            {:ok, Map.put(counts, :verified_empty?, verification.entries == [])}
          end

        true ->
          purge_version_pages(object_key, remaining - 1, counts, context)
      end
    end
  end

  defp list_exact_versions(object_key, context) do
    query = [
      {"versions", ""},
      {"prefix", object_key},
      {"max-keys", Integer.to_string(@version_page_size)}
    ]

    with {:ok, %{url: url}} <- Presigner.presign("GET", "", :internal, %{}, query),
         request <- Finch.build(:get, url),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           bounded_request(request, context),
         {:ok, listing} <- VersionListing.parse(body) do
      entries = Enum.filter(listing.entries, &(&1.key == object_key))
      {:ok, %{listing | entries: entries}}
    else
      {:error, _} = error -> error
      {:ok, %{status: status}} -> {:error, {:object_storage_status, status}}
      false -> {:error, :object_version_listing_failed}
      _ -> {:error, :object_version_listing_failed}
    end
  end

  defp delete_listed_versions(object_key, entries, context) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case delete_listed_version(object_key, entry.version_id, context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_listed_version(object_key, version, context)
       when is_binary(object_key) and is_binary(version) and version != "" do
    with {:ok, %{url: url}} <-
           Presigner.presign("DELETE", object_key, :internal, %{}, [{"versionId", version}]),
         request <- Finch.build(:delete, url),
         {:ok, %{status: status}} when status in 200..299 or status == 404 <-
           bounded_request(request, context) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:object_storage_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :object_deletion_failed}
    end
  end

  defp delete_listed_version(_object_key, _version, _context),
    do: {:error, :object_version_listing_invalid}

  # Finch's HTTP/1 request timeout is best effort and excludes checkout/connect.
  # The supervised task bounds the complete local operation and is cancelled
  # before returning an unknown result to the caller holding governance locks.
  defp bounded_request(request, context) do
    remaining = context.deadline - context.clock.()

    if remaining <= 1 do
      {:error, :object_storage_purge_timeout}
    else
      budget = min(remaining, @request_budget_ms)
      pool = min(5_000, div(budget, 2))
      receive = budget - pool
      options = [pool_timeout: pool, request_timeout: receive, receive_timeout: receive]

      task =
        Task.Supervisor.async_nolink(CommsIntegrations.TaskSupervisor, fn ->
          context.requester.(request, @max_version_listing_bytes, options)
        end)

      case Task.yield(task, budget) do
        {:ok, result} ->
          with :ok <- before_deadline(context), do: result

        {:exit, _reason} ->
          {:error, :object_storage_unavailable}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :object_storage_purge_timeout}
      end
    end
  rescue
    _ -> {:error, :object_storage_unavailable}
  end

  defp before_deadline(context) do
    if context.clock.() < context.deadline,
      do: :ok,
      else: {:error, :object_storage_purge_timeout}
  end

  defp monotonic_ms(), do: System.monotonic_time(:millisecond)

  defp count_deleted(counts, entries) do
    Enum.reduce(entries, counts, fn
      %{kind: :version}, acc ->
        Map.update!(acc, :deleted_versions, &(&1 + 1))

      %{kind: :delete_marker}, acc ->
        Map.update!(acc, :deleted_markers, &(&1 + 1))
    end)
  end

  defp stream_response(request, max_bytes, options) do
    initial = %{status: nil, bytes: 0, chunks: [], error: nil}

    Finch.stream_while(
      request,
      CommsIntegrations.Finch,
      initial,
      fn
        {:status, status}, acc ->
          {:cont, %{acc | status: status}}

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
      options
    )
    |> case do
      {:ok, %{error: nil, status: status, chunks: chunks}} when is_integer(status) ->
        {:ok, %{status: status, body: IO.iodata_to_binary(chunks)}}

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
