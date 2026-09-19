defmodule CommsCore.Governance.RetentionReconciliation do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Governance.{RetentionDefaultsReader, RetentionExecution, RetentionPolicy}
  alias CommsCore.{Repo, RuntimePorts}

  def reconcile_retention_schedules(cursor, caller) do
    with true <- RuntimePorts.authorized_job_worker?(:retention_reconciler, caller),
         :ok <- validate_cursor(cursor) do
      tenants = tenant_ids(cursor)

      result =
        Enum.reduce_while(tenants, {:ok, 0}, fn tenant_id, {:ok, count} ->
          case repair(tenant_id) do
            {:ok, repaired} -> {:cont, {:ok, count + repaired}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      with {:ok, repaired} <- result do
        {:ok,
         %{repaired: repaired, has_more: length(tenants) == 100, next_cursor: List.last(tenants)}}
      end
    else
      false -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  defp validate_cursor(nil), do: :ok

  defp validate_cursor(cursor) when is_binary(cursor) do
    case Ecto.UUID.cast(cursor) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_retention_cursor}
    end
  end

  defp validate_cursor(_), do: {:error, :invalid_retention_cursor}

  defp tenant_ids(cursor) do
    policies =
      RetentionPolicy
      |> where([policy], policy.status == :active)
      |> then(fn query ->
        if cursor, do: where(query, [policy], policy.tenant_id > ^cursor), else: query
      end)
      |> select([policy], policy.tenant_id)
      |> distinct(true)
      |> order_by([policy], asc: policy.tenant_id)
      |> limit(100)
      |> Repo.all()

    (policies ++ RetentionDefaultsReader.tenant_ids(cursor))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(100)
  end

  defp repair(tenant_id) do
    worker = RuntimePorts.job_worker_name!(:retention)

    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "retention-reconciliation:#{tenant_id}"
      ])

      scheduled? =
        Repo.exists?(
          from(job in Oban.Job,
            where:
              job.worker == ^worker and
                job.state in ["available", "scheduled", "executing", "retryable"] and
                fragment("?->>'tenant_id'", job.args) == ^tenant_id
          )
        )

      if scheduled? do
        0
      else
        case RetentionExecution.enqueue_retention_scan(tenant_id, 0, &Oban.insert/1) do
          :ok -> 1
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end
end
