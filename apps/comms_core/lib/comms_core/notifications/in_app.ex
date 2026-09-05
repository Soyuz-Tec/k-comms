defmodule CommsCore.Notifications.InApp do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Notifications.Intent
  alias CommsCore.Repo

  @max_limit 100
  @recovery_event_type "account.password_recovery.requested.v1"

  def list(subject, opts \\ %{}) do
    with {:ok, filter} <- notification_filter(value(opts, :filter)),
         {:ok, cursor} <- notification_cursor(value(opts, :cursor), filter) do
      limit = opts |> value(:limit) |> integer(50) |> max(1) |> min(@max_limit)

      results =
        subject
        |> visible_query()
        |> filter_notifications(filter)
        |> before_cursor(cursor)
        |> order_by([intent], desc: intent.inserted_at, desc: intent.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      notifications = Enum.take(results, limit)
      has_more = length(results) > limit

      {:ok,
       %{
         notifications: notifications,
         unread_count: unread_count_query(subject),
         limit: limit,
         has_more: has_more,
         next_cursor: if(has_more, do: cursor_for(List.last(notifications), filter), else: nil)
       }}
    end
  end

  defp notification_filter(nil), do: {:ok, "all"}
  defp notification_filter(""), do: {:ok, "all"}
  defp notification_filter(filter) when filter in ["all", "unread"], do: {:ok, filter}
  defp notification_filter(_), do: {:error, :invalid_notification_filter}

  defp filter_notifications(query, "unread"),
    do: where(query, [intent], is_nil(intent.read_at))

  defp filter_notifications(query, "all"), do: query

  defp notification_cursor(nil, _filter), do: {:ok, nil}
  defp notification_cursor("", _filter), do: {:ok, nil}

  defp notification_cursor(value, filter) when is_binary(value) and byte_size(value) <= 512 do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok,
          %{"v" => 1, "inserted_at" => inserted_at, "notification_id" => id, "filter" => ^filter}} <-
           Jason.decode(decoded),
         true <- is_binary(inserted_at) and is_binary(id),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(inserted_at),
         {:ok, notification_id} <- Ecto.UUID.cast(id) do
      {:ok, {DateTime.truncate(timestamp, :microsecond), notification_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp notification_cursor(_value, _filter), do: {:error, :invalid_cursor}

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, {timestamp, notification_id}) do
    where(
      query,
      [intent],
      intent.inserted_at < ^timestamp or
        (intent.inserted_at == ^timestamp and intent.id < ^notification_id)
    )
  end

  defp cursor_for(intent, filter) do
    %{
      v: 1,
      inserted_at: DateTime.to_iso8601(intent.inserted_at),
      notification_id: intent.id,
      filter: filter
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  def unread_count(subject), do: {:ok, unread_count_query(subject)}

  def mark_read(id, subject) when is_binary(id) do
    update_one(id, subject, fn intent, timestamp ->
      if intent.read_at do
        intent
      else
        intent
        |> Intent.changeset(%{read_at: timestamp})
        |> Repo.update!()
      end
    end)
  end

  def dismiss(id, subject) when is_binary(id) do
    update_one(id, subject, fn intent, timestamp ->
      if intent.dismissed_at do
        intent
      else
        intent
        |> Intent.changeset(%{
          read_at: intent.read_at || timestamp,
          dismissed_at: timestamp
        })
        |> Repo.update!()
      end
    end)
  end

  def mark_all_read(subject) do
    Repo.transaction(fn ->
      timestamp = now()

      {updated_count, _} =
        subject
        |> scoped_query()
        |> where([intent], is_nil(intent.dismissed_at) and is_nil(intent.read_at))
        |> Repo.update_all(set: [read_at: timestamp, updated_at: timestamp])

      %{
        updated_count: updated_count,
        unread_count: unread_count_query(subject)
      }
    end)
    |> unwrap_transaction()
  end

  defp update_one(id, subject, updater) do
    Repo.transaction(fn ->
      intent =
        subject
        |> scoped_query()
        |> where([intent], intent.id == ^id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if intent, do: updater.(intent, now()), else: Repo.rollback(:not_found)
    end)
    |> unwrap_transaction()
  end

  defp visible_query(subject) do
    subject
    |> scoped_query()
    |> where([intent], is_nil(intent.dismissed_at))
  end

  defp scoped_query(subject) do
    from(intent in Intent,
      where:
        intent.tenant_id == ^value(subject, :tenant_id) and
          intent.user_id == ^value(subject, :user_id) and
          intent.channel == :in_app and
          intent.event_type != @recovery_event_type
    )
  end

  defp unread_count_query(subject) do
    subject
    |> scoped_query()
    |> where([intent], is_nil(intent.read_at) and is_nil(intent.dismissed_at))
    |> Repo.aggregate(:count)
  end

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
