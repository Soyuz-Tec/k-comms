defmodule CommsCore.Messaging.Search do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Messaging.{Message, ReadModel}

  @default_search_limit 50
  @max_search_limit 200

  def search(query_text, subject, opts \\ []) when is_binary(query_text) do
    case search_page(query_text, subject, opts) do
      {:ok, %{messages: messages}} -> {:ok, messages}
      {:error, _reason} = error -> error
    end
  end

  def search_page(query_text, subject, opts \\ [])
      when is_binary(query_text) and is_map(subject) and is_list(opts) do
    query_text = String.trim(query_text)
    limit_count = clamp_limit(Keyword.get(opts, :limit, @default_search_limit), @max_search_limit)

    if query_text == "" do
      {:ok,
       %{
         messages: [],
         sender_labels: [],
         limit: limit_count,
         has_more: false,
         next_cursor: nil
       }}
    else
      with {:ok, conversation_id} <- optional_search_uuid(Keyword.get(opts, :conversation_id)),
           {:ok, sender_user_id} <- optional_search_uuid(Keyword.get(opts, :sender_user_id)),
           {:ok, after_at} <- optional_search_datetime(Keyword.get(opts, :after)),
           {:ok, before_at} <- optional_search_datetime(Keyword.get(opts, :before)),
           :ok <- validate_search_range(after_at, before_at),
           {:ok, cursor} <- optional_search_cursor(Keyword.get(opts, :cursor)),
           {:ok, authorization_query} <- search_authorization_query(subject) do
        results =
          from(m in Message,
            join: authorization in subquery(authorization_query),
            on: authorization.conversation_id == m.conversation_id,
            where:
              m.tenant_id == ^value(subject, :tenant_id) and
                m.status == :active and
                fragment(
                  "to_tsvector('simple', coalesce(?, '')) @@ plainto_tsquery('simple', ?)",
                  m.body,
                  ^query_text
                ),
            order_by: [desc: m.inserted_at, desc: m.id],
            preload: []
          )
          |> maybe_filter_search(:conversation_id, conversation_id)
          |> maybe_filter_search(:sender_user_id, sender_user_id)
          |> maybe_filter_search(:after, after_at)
          |> maybe_filter_search(:before, before_at)
          |> maybe_before_search_cursor(cursor)
          |> limit(^(limit_count + 1))
          |> Repo.all()

        has_more = length(results) > limit_count
        messages = results |> Enum.take(limit_count) |> ReadModel.hydrate_messages()

        {:ok,
         %{
           messages: messages,
           sender_labels: ReadModel.retained_sender_labels(messages, subject, opts),
           limit: limit_count,
           has_more: has_more,
           next_cursor: if(has_more, do: search_cursor_for(List.last(messages)), else: nil)
         }}
      end
    end
  end

  defp search_authorization_query(subject) do
    if value(subject, :auth_type) == :service do
      Conversations.active_service_membership_authorization_query(subject, "search:read")
    else
      with {:ok, grant} <- Accounts.access_grant(subject) do
        {:ok, Conversations.active_membership_authorization_query(grant)}
      end
    end
  end

  defp optional_search_uuid(nil), do: {:ok, nil}
  defp optional_search_uuid(""), do: {:ok, nil}

  defp optional_search_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_search_query}
    end
  end

  defp optional_search_uuid(_value), do: {:error, :invalid_search_query}

  defp optional_search_datetime(nil), do: {:ok, nil}
  defp optional_search_datetime(""), do: {:ok, nil}

  defp optional_search_datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp optional_search_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, DateTime.truncate(timestamp, :microsecond)}
      {:error, _reason} -> {:error, :invalid_search_query}
    end
  end

  defp optional_search_datetime(_value), do: {:error, :invalid_search_query}

  defp validate_search_range(nil, _before_at), do: :ok
  defp validate_search_range(_after_at, nil), do: :ok

  defp validate_search_range(after_at, before_at) do
    if DateTime.compare(after_at, before_at) == :lt,
      do: :ok,
      else: {:error, :invalid_search_query}
  end

  defp optional_search_cursor(nil), do: {:ok, nil}
  defp optional_search_cursor(""), do: {:ok, nil}

  defp optional_search_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"inserted_at" => inserted_at, "id" => id, "v" => 1}} <- Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(inserted_at),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {DateTime.truncate(timestamp, :microsecond), uuid}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_search_cursor(_value), do: {:error, :invalid_cursor}

  defp maybe_filter_search(query, _field, nil), do: query

  defp maybe_filter_search(query, :conversation_id, value),
    do: where(query, [message, ...], message.conversation_id == ^value)

  defp maybe_filter_search(query, :sender_user_id, value),
    do: where(query, [message, ...], message.sender_user_id == ^value)

  defp maybe_filter_search(query, :after, value),
    do: where(query, [message, ...], message.inserted_at >= ^value)

  defp maybe_filter_search(query, :before, value),
    do: where(query, [message, ...], message.inserted_at < ^value)

  defp maybe_before_search_cursor(query, nil), do: query

  defp maybe_before_search_cursor(query, {timestamp, id}) do
    where(
      query,
      [message, ...],
      message.inserted_at < ^timestamp or
        (message.inserted_at == ^timestamp and message.id < ^id)
    )
  end

  defp search_cursor_for(nil), do: nil

  defp search_cursor_for(message) do
    %{v: 1, inserted_at: DateTime.to_iso8601(message.inserted_at), id: message.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp clamp_limit(value, max_limit), do: value |> integer(100) |> max(1) |> min(max_limit)
  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
