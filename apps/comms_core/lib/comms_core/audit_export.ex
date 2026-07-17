defmodule CommsCore.AuditExport do
  alias CommsCore.{Audit, Authorization, Repo}

  @default_limit 1_000
  @maximum_limit 5_000
  @filter_keys [:q, :action, :resource_type, :actor_user_id, :request_id, :after, :before]

  def export(params, subject) when is_map(params) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- Authorization.authorize(:audit_tenant, subject, %{id: tenant_id}),
         {:ok, after_timestamp} <- optional_datetime(value(params, :after)),
         {:ok, before_timestamp} <- optional_datetime(value(params, :before)),
         {:ok, actor_user_id} <- optional_uuid(value(params, :actor_user_id)),
         {:ok, query_text} <- optional_string(value(params, :q), 200),
         {:ok, action} <- optional_string(value(params, :action), 200),
         {:ok, resource_type} <- optional_string(value(params, :resource_type), 200),
         {:ok, request_id} <- optional_string(value(params, :request_id), 200) do
      limit = parse_limit(value(params, :limit))

      filters = %{
        q: query_text,
        action: action,
        resource_type: resource_type,
        actor_user_id: actor_user_id,
        request_id: request_id,
        after: after_timestamp,
        before: before_timestamp
      }

      Repo.transaction(fn ->
        results =
          filters
          |> Map.merge(%{tenant_id: tenant_id, limit: limit + 1})
          |> Audit.list()

        truncated = length(results) > limit
        events = Enum.take(results, limit)

        Audit.record(%{
          tenant_id: tenant_id,
          actor_user_id: value(subject, :user_id),
          action: "audit.export",
          resource_type: "tenant",
          resource_id: tenant_id,
          request_id: value(subject, :request_id),
          metadata: %{
            filters: safe_filters(filters),
            returned_count: length(events),
            truncated: truncated,
            maximum_rows: @maximum_limit
          }
        })
        |> audit_or_rollback()

        %{
          csv: encode_csv(events),
          count: length(events),
          truncated: truncated,
          filename: filename()
        }
      end)
      |> transaction_result()
    end
  end

  def export(_, _), do: {:error, :forbidden}

  defp encode_csv(events) do
    header = [
      "inserted_at",
      "actor_user_id",
      "action",
      "resource_type",
      "resource_id",
      "request_id",
      "metadata"
    ]

    rows =
      Enum.map(events, fn event ->
        [
          DateTime.to_iso8601(event.inserted_at),
          event.actor_user_id,
          event.action,
          event.resource_type,
          event.resource_id,
          event.request_id,
          Jason.encode!(event.metadata || %{})
        ]
      end)

    ([header] ++ rows)
    |> Enum.map_join("\r\n", fn row -> Enum.map_join(row, ",", &csv_cell/1) end)
    |> Kernel.<>("\r\n")
  end

  defp csv_cell(nil), do: "\"\""

  defp csv_cell(value) do
    text = value |> to_string() |> String.replace(<<0>>, "")
    text = if Regex.match?(~r/^\s*[=+\-@\t\r]/u, text), do: "'" <> text, else: text
    "\"" <> String.replace(text, "\"", "\"\"") <> "\""
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

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}

  defp optional_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_search_query}
    end
  end

  defp optional_string(nil, _maximum), do: {:ok, nil}
  defp optional_string("", _maximum), do: {:ok, nil}

  defp optional_string(value, maximum) when is_binary(value) do
    normalized = String.trim(value)

    if String.length(normalized) <= maximum,
      do: {:ok, normalized},
      else: {:error, :invalid_search_query}
  end

  defp optional_string(_, _maximum), do: {:error, :invalid_search_query}

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@maximum_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parse_limit(parsed)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp safe_filters(params) do
    @filter_keys
    |> Enum.reduce(%{}, fn key, filters ->
      case value(params, key) do
        nil -> filters
        "" -> filters
        _filter when key == :q -> Map.put(filters, :query_present, true)
        filter -> Map.put(filters, key, to_string(filter))
      end
    end)
  end

  defp filename do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    "k-comms-audit-#{timestamp}.csv"
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
