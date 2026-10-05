defmodule CommsCore.Conversations.UsageReports do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Conversations.{Conversation, UsageProjection, UsageQuery}
  alias CommsCore.Repo
  alias CommsCore.Accounts

  @spec project(UsageQuery.t(), map()) ::
          {:ok, UsageProjection.t()}
          | {:error, :invalid_usage_query | :forbidden | :step_up_required}
  def project(%UsageQuery{} = query, subject) when is_map(subject) do
    with {:ok, {start_at, end_at, days}} <- UsageQuery.range(query),
         {:ok, _} <- authorize(query, subject) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          case Accounts.lock_content_write_grant(subject, deadline) do
            {:ok, grant} -> grant_or_rollback!(query, grant)
            _ -> Repo.rollback(:forbidden)
          end

          projection = aggregate(query.tenant_id, start_at, end_at, days, deadline)
          if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)

          case authorize(query, subject) do
            {:ok, _} -> projection
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout: 20_000
      )
    end
  end

  def project(_, _), do: {:error, :invalid_usage_query}

  defp authorize(query, subject) do
    case Accounts.access_grant(subject) do
      {:ok, grant} -> check_grant(query, grant)
      _ -> {:error, :forbidden}
    end
  end

  defp check_grant(
         query,
         %{
           tenant_id: tenant_id,
           account_type: :human,
           access_scope: :workspace,
           role: role,
           step_up_recent?: recent
         } = grant
       )
       when role in [:owner, :admin] do
    cond do
      tenant_id != query.tenant_id -> {:error, :forbidden}
      not recent -> {:error, :step_up_required}
      true -> {:ok, grant}
    end
  end

  defp check_grant(_, _), do: {:error, :forbidden}

  defp grant_or_rollback!(query, grant) do
    case check_grant(query, grant) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp aggregate(tenant_id, start_at, end_at, days, deadline) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    budget!(deadline)

    earliest =
      Repo.one(
        from(row in Conversation,
          where: row.tenant_id == ^tenant_id,
          select: min(row.inserted_at)
        )
      )

    budget!(deadline)

    current = %{
      active_conversations:
        Repo.aggregate(
          from(row in Conversation,
            where: row.tenant_id == ^tenant_id and is_nil(row.archived_at)
          ),
          :count
        )
    }

    budget!(deadline)

    rows =
      Repo.all(
        from(row in Conversation,
          where:
            row.tenant_id == ^tenant_id and row.inserted_at >= ^start_at and
              row.inserted_at < ^end_at,
          group_by: [fragment("?::date", row.inserted_at), row.kind],
          select: {fragment("?::date", row.inserted_at), row.kind, count(row.id)}
        )
      )

    daily =
      daily_counts(days, rows, %{direct_created: 0, group_created: 0, channel_created: 0}, %{
        direct: :direct_created,
        group: :group_created,
        channel: :channel_created
      })

    %UsageProjection{
      observed_at: observed_at,
      earliest_retained_at: earliest,
      current: current,
      daily: daily
    }
  end

  defp daily_counts(days, rows, zeroes, names) do
    grouped =
      Enum.reduce(rows, %{}, fn {date, category, count}, acc ->
        metric = Map.fetch!(names, category)
        Map.update(acc, date, Map.put(zeroes, metric, count), &Map.put(&1, metric, count))
      end)

    Enum.map(days, fn date -> %{date: date, metrics: Map.get(grouped, date, zeroes)} end)
  end

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [Integer.to_string(remaining)]
    )
  end
end
