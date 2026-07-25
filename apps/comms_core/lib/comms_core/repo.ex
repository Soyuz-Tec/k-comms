defmodule CommsCore.Repo do
  use Ecto.Repo, otp_app: :comms_core, adapter: Ecto.Adapters.Postgres

  alias Ecto.Adapters.SQL

  @index_name ~r/\A[a-z][a-z0-9_]*\z/

  @doc false
  @spec release_migration_preflight!() :: [[term()]]
  def release_migration_preflight! do
    SQL.query!(
      __MODULE__,
      """
      SELECT
        current_setting('application_name'),
        (SELECT setting::bigint FROM pg_settings WHERE name = 'lock_timeout'),
        (SELECT setting::bigint FROM pg_settings WHERE name = 'statement_timeout'),
        (
          SELECT count(*)::bigint
          FROM pg_stat_activity AS activity
          WHERE activity.datname = current_database()
            AND activity.backend_type = 'client backend'
            AND activity.application_name
                IS DISTINCT FROM current_setting('application_name')
        )
      """,
      []
    ).rows
  end

  @doc false
  @spec active_oban_job_count!(String.t()) :: non_neg_integer()
  def active_oban_job_count!(worker_name)
      when is_binary(worker_name) and worker_name != "" do
    rows =
      SQL.query!(
        __MODULE__,
        """
        SELECT count(*)::bigint
        FROM oban_jobs
        WHERE worker = $1
          AND state::text = ANY($2::text[])
        """,
        [
          worker_name,
          ["available", "scheduled", "executing", "retryable"]
        ]
      ).rows

    case rows do
      [[count]] when is_integer(count) and count >= 0 -> count
      _ -> raise "active Oban job count returned an invalid result"
    end
  end

  @doc false
  @spec ensure_valid_concurrent_index!(String.t(), (-> term()), (-> term())) :: :ok
  def ensure_valid_concurrent_index!(index_name, drop_invalid, create_index)
      when is_binary(index_name) and is_function(drop_invalid, 0) and
             is_function(create_index, 0) do
    validate_index_name!(index_name)

    case concurrent_index_state(index_name) do
      :valid ->
        :ok

      :invalid ->
        drop_invalid.()
        create_and_assert_concurrent_index!(index_name, create_index)

      :missing ->
        create_and_assert_concurrent_index!(index_name, create_index)
    end
  end

  defp create_and_assert_concurrent_index!(index_name, create_index) do
    create_index.()

    case concurrent_index_state(index_name) do
      :valid ->
        :ok

      :invalid ->
        raise "concurrent index #{index_name} exists but PostgreSQL reports it as invalid"

      :missing ->
        raise "concurrent index #{index_name} was not created"
    end
  end

  defp concurrent_index_state(index_name) do
    result =
      SQL.query!(
        __MODULE__,
        """
        SELECT index_record.indisvalid
        FROM pg_catalog.pg_index AS index_record
        JOIN pg_catalog.pg_class AS index_relation
          ON index_relation.oid = index_record.indexrelid
        JOIN pg_catalog.pg_namespace AS index_namespace
          ON index_namespace.oid = index_relation.relnamespace
        WHERE index_namespace.nspname = current_schema()
          AND index_relation.relname = $1
        """,
        [index_name]
      )

    case result.rows do
      [] -> :missing
      [[true]] -> :valid
      [[false]] -> :invalid
    end
  end

  defp validate_index_name!(index_name) do
    unless Regex.match?(@index_name, index_name) do
      raise ArgumentError, "invalid concurrent index name"
    end
  end
end
