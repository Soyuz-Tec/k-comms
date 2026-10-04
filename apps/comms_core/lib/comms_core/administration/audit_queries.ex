defmodule CommsCore.Administration.AuditQueries do
  @moduledoc false

  alias CommsCore.Administration.AuthorizationPolicy
  alias CommsCore.Audit
  alias CommsCore.Repo

  @default_limit 50
  @max_limit 100

  def list(params, subject) when is_map(params) do
    with :ok <- AuthorizationPolicy.authorize(:audit_tenant, subject),
         {:ok, cursor} <- optional_cursor(value(params, :cursor)),
         {:ok, before} <- optional_cursor(value(params, :before)),
         {:ok, after_timestamp} <- optional_datetime(value(params, :after)),
         {:ok, query_text} <- optional_string(value(params, :q)),
         {:ok, action} <- optional_string(value(params, :action)),
         {:ok, resource_type} <- optional_string(value(params, :resource_type)),
         {:ok, request_id} <- optional_string(value(params, :request_id)),
         {:ok, actor_user_id} <- optional_uuid(value(params, :actor_user_id)) do
      limit = parse_limit(value(params, :limit))

      Repo.transaction(fn ->
        events =
          Audit.list(%{
            tenant_id: value(subject, :tenant_id),
            q: query_text,
            action: action,
            resource_type: resource_type,
            actor_user_id: actor_user_id,
            request_id: request_id,
            before: earlier_boundary(cursor, before),
            after: after_timestamp,
            limit: limit + 1
          })

        has_more = length(events) > limit
        events = Enum.take(events, limit)

        audit!(subject, "audit.read", "tenant", value(subject, :tenant_id), %{
          filters:
            audit_filters(%{
              action: action,
              resource_type: resource_type,
              actor_user_id: actor_user_id,
              request_id: request_id
            }),
          query_present: is_binary(query_text) and query_text != "",
          returned_count: length(events)
        })

        %{
          events: events,
          limit: limit,
          next_cursor: if(has_more, do: cursor_for(List.last(events)), else: nil)
        }
      end)
      |> transaction_result()
    end
  end

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(""), do: {:ok, nil}
  defp optional_datetime(%DateTime{} = value), do: {:ok, value}

  defp optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp optional_datetime(_), do: {:error, :invalid_datetime}

  # Match export search semantics without recording potentially sensitive text.
  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(""), do: {:ok, nil}

  defp optional_string(value) when is_binary(value) do
    query = String.trim(value)
    if String.length(query) <= 200, do: {:ok, query}, else: {:error, :invalid_search_query}
  end

  defp optional_string(_), do: {:error, :invalid_search_query}

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}

  defp optional_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_search_query}
    end
  end

  defp optional_cursor(nil), do: {:ok, nil}
  defp optional_cursor(""), do: {:ok, nil}

  defp optional_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"inserted_at" => timestamp, "id" => id}} <- Jason.decode(decoded),
         {:ok, parsed, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, canonical_id} <- Ecto.UUID.cast(id) do
      {:ok, {parsed, canonical_id}}
    else
      _ ->
        case optional_datetime(value) do
          {:ok, parsed} -> {:ok, {parsed, nil}}
          {:error, _} -> {:error, :invalid_cursor}
        end
    end
  end

  defp optional_cursor(_), do: {:error, :invalid_cursor}

  defp earlier_boundary(nil, boundary), do: boundary
  defp earlier_boundary(boundary, nil), do: boundary

  defp earlier_boundary({cursor_time, cursor_id} = cursor, {before_time, before_id} = before) do
    case DateTime.compare(cursor_time, before_time) do
      :lt -> cursor
      :gt -> before
      :eq when is_nil(cursor_id) -> cursor
      :eq when is_nil(before_id) -> before
      :eq -> if cursor_id < before_id, do: cursor, else: before
    end
  end

  defp cursor_for(nil), do: nil

  defp cursor_for(event) do
    %{inserted_at: DateTime.to_iso8601(event.inserted_at), id: event.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp audit_filters(filters) do
    Map.reject(filters, fn {_key, value} -> value in [nil, ""] end)
  end

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_limit(number)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp audit!(subject, action, resource_type, resource_id, metadata) do
    Audit.record(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)
  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
