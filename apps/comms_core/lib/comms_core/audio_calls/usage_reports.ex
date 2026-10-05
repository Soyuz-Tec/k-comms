defmodule CommsCore.AudioCalls.UsageReports do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.AudioCalls.{AudioCall, UsageProjection, UsageQuery}
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
        from(row in AudioCall, where: row.tenant_id == ^tenant_id, select: min(row.started_at))
      )

    budget!(deadline)

    active =
      Repo.all(
        from(row in AudioCall,
          where: row.tenant_id == ^tenant_id and row.status in [:active, :ending],
          group_by: row.status,
          select: {row.status, count(row.id)}
        )
      )
      |> Map.new()

    current = %{
      current_active: Map.get(active, :active, 0),
      current_ending: Map.get(active, :ending, 0)
    }

    budget!(deadline)

    rows =
      Repo.all(
        from(row in AudioCall,
          where:
            row.tenant_id == ^tenant_id and row.started_at >= ^start_at and row.started_at < ^end_at,
          group_by: [fragment("?::date", row.started_at), row.status, row.media_kind],
          select: {fragment("?::date", row.started_at), row.status, row.media_kind, count(row.id)}
        )
      )

    zeroes = %{
      status_active: 0,
      status_ending: 0,
      status_ended: 0,
      audio_started: 0,
      video_started: 0,
      started: 0,
      observed_room_seconds: 0
    }

    grouped =
      Enum.reduce(rows, %{}, fn {date, status, kind, count}, acc ->
        metrics = Map.get(acc, date, zeroes)

        metrics =
          metrics
          |> Map.update!(status_metric(status), &(&1 + count))
          |> Map.update!(kind_metric(kind), &(&1 + count))
          |> Map.update!(:started, &(&1 + count))

        Map.put(acc, date, metrics)
      end)

    daily =
      Enum.map(days, fn date ->
        budget!(deadline)
        day_start = DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
        day_end = DateTime.add(day_start, 86_400, :second)

        seconds =
          Repo.one(
            from(row in AudioCall,
              where:
                row.tenant_id == ^tenant_id and not is_nil(row.started_at) and
                  row.started_at < ^day_end and row.expires_at > ^day_start and
                  (is_nil(row.ended_at) or row.ended_at > ^day_start),
              select:
                fragment(
                  "coalesce(sum(greatest(0, floor(extract(epoch from (least(coalesce(?, ?), ?, ?, ?) - greatest(?, ?)))))), 0)::bigint",
                  row.ended_at,
                  type(^observed_at, :utc_datetime_usec),
                  row.expires_at,
                  type(^day_end, :utc_datetime_usec),
                  type(^observed_at, :utc_datetime_usec),
                  row.started_at,
                  type(^day_start, :utc_datetime_usec)
                )
            )
          )

        %{
          date: date,
          metrics: Map.put(Map.get(grouped, date, zeroes), :observed_room_seconds, seconds)
        }
      end)

    %UsageProjection{
      observed_at: observed_at,
      earliest_retained_at: earliest,
      current: current,
      daily: daily
    }
  end

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [Integer.to_string(remaining)]
    )
  end

  defp status_metric(:active), do: :status_active
  defp status_metric(:ending), do: :status_ending
  defp status_metric(:ended), do: :status_ended
  defp kind_metric(:audio), do: :audio_started
  defp kind_metric(:video), do: :video_started
end
