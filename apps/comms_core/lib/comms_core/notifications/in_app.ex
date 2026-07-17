defmodule CommsCore.Notifications.InApp do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Notifications.Intent
  alias CommsCore.Repo

  @max_limit 100
  @recovery_event_type "account.password_recovery.requested.v1"

  def list(subject, opts \\ %{}) do
    query = visible_query(subject)
    limit = opts |> value(:limit) |> integer(50) |> max(1) |> min(@max_limit)

    notifications =
      query
      |> order_by([intent], desc: intent.inserted_at, desc: intent.id)
      |> limit(^limit)
      |> Repo.all()

    {:ok, %{notifications: notifications, unread_count: unread_count_query(subject)}}
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
