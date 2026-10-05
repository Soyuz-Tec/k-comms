defmodule CommsCore.Accounts.UsageReports do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Accounts.{User, UsageProjection, UsageQuery}
  alias CommsCore.Repo
  alias CommsCore.Accounts.{AccessControl, ContentWriteGrant}

  @spec disclose(map(), (-> {:ok, binary()} | {:error, atom()})) ::
          {:ok, binary()} | {:error, atom()}
  def disclose(subject, encoder) when is_map(subject) and is_function(encoder, 0) do
    with {:ok, initial_grant} <- AccessControl.access_grant(subject),
         {:ok, _} <- check_grant(%{tenant_id: initial_grant.tenant_id}, initial_grant) do
      query = %{tenant_id: initial_grant.tenant_id}
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          case ContentWriteGrant.lock(subject, deadline) do
            {:ok, grant} -> grant_or_rollback!(query, grant)
            _ -> Repo.rollback(:forbidden)
          end

          body =
            case encoder.() do
              {:ok, binary} when is_binary(binary) and byte_size(binary) <= 1_048_576 -> binary
              {:ok, binary} when is_binary(binary) -> Repo.rollback(:usage_report_too_large)
              {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
              _ -> Repo.rollback(:invalid_usage_report)
            end

          budget!(deadline)

          case authorize(query, subject) do
            {:ok, _} -> body
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout: 20_000
      )
    else
      {:error, :step_up_required} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def disclose(_, _), do: {:error, :forbidden}

  @spec project(UsageQuery.t(), map()) ::
          {:ok, UsageProjection.t()}
          | {:error, :invalid_usage_query | :forbidden | :step_up_required}
  def project(%UsageQuery{} = query, subject) when is_map(subject) do
    with {:ok, {start_at, end_at, days}} <- UsageQuery.range(query),
         {:ok, _} <- authorize(query, subject) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          case ContentWriteGrant.lock(subject, deadline) do
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
    case AccessControl.access_grant(subject) do
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
      Repo.one(from(row in User, where: row.tenant_id == ^tenant_id, select: min(row.inserted_at)))

    budget!(deadline)

    active =
      Repo.all(
        from(row in User,
          where:
            row.tenant_id == ^tenant_id and row.status == :active and
              row.account_type in [:human, :service],
          group_by: row.account_type,
          select: {row.account_type, count(row.id)}
        )
      )
      |> Map.new()

    current = %{
      active_humans: Map.get(active, :human, 0),
      active_services: Map.get(active, :service, 0)
    }

    budget!(deadline)

    rows =
      Repo.all(
        from(row in User,
          where:
            row.tenant_id == ^tenant_id and row.inserted_at >= ^start_at and
              row.inserted_at < ^end_at and row.account_type in [:human, :service],
          group_by: [fragment("?::date", row.inserted_at), row.account_type],
          select: {fragment("?::date", row.inserted_at), row.account_type, count(row.id)}
        )
      )

    daily =
      daily_counts(days, rows, %{humans_created: 0, services_created: 0}, %{
        human: :humans_created,
        service: :services_created
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
