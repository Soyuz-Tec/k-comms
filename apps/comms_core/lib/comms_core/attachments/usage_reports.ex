defmodule CommsCore.Attachments.UsageReports do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Attachments.{Attachment, UsageProjection, UsageQuery}
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
        from(row in Attachment, where: row.tenant_id == ^tenant_id, select: min(row.inserted_at))
      )

    ready =
      from(row in Attachment,
        where:
          row.tenant_id == ^tenant_id and row.status == :ready and row.scan_status == :clean and
            not is_nil(row.object_version_id) and not is_nil(row.object_etag) and
            row.verified_checksum_sha256 == row.checksum_sha256
      )

    budget!(deadline)

    {ready_count, ready_bytes} =
      Repo.one(
        from(row in ready,
          select: {count(row.id), fragment("coalesce(sum(?), 0)::bigint", row.byte_size)}
        )
      )

    current = %{ready_retained_count: ready_count, ready_retained_bytes: ready_bytes}
    budget!(deadline)

    created =
      Repo.all(
        from(row in Attachment,
          where:
            row.tenant_id == ^tenant_id and row.inserted_at >= ^start_at and
              row.inserted_at < ^end_at,
          group_by: fragment("?::date", row.inserted_at),
          select: {fragment("?::date", row.inserted_at), count(row.id)}
        )
      )
      |> Map.new()

    budget!(deadline)

    ready_rows =
      Repo.all(
        from(row in ready,
          where: row.inserted_at >= ^start_at and row.inserted_at < ^end_at,
          group_by: fragment("?::date", row.inserted_at),
          select:
            {fragment("?::date", row.inserted_at), count(row.id),
             fragment("coalesce(sum(?), 0)::bigint", row.byte_size)}
        )
      )
      |> Map.new(fn {date, count, bytes} -> {date, {count, bytes}} end)

    daily =
      Enum.map(days, fn date ->
        {count, bytes} = Map.get(ready_rows, date, {0, 0})

        %{
          date: date,
          metrics: %{created: Map.get(created, date, 0), ready_count: count, ready_bytes: bytes}
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
end
