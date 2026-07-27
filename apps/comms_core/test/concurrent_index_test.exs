defmodule CommsCore.ConcurrentIndexTest do
  use ExUnit.Case, async: false

  alias CommsCore.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  test "repairs an invalid concurrent-index remnant and keeps a valid retry" do
    suffix = System.unique_integer([:positive, :monotonic])
    table_name = "concurrent_index_recovery_#{suffix}"
    index_name = "#{table_name}_index"

    Sandbox.unboxed_run(Repo, fn ->
      try do
        SQL.query!(Repo, ~s|CREATE TABLE "#{table_name}" (value integer NOT NULL)|, [])
        SQL.query!(Repo, ~s|INSERT INTO "#{table_name}" (value) VALUES (1), (1)|, [])

        assert_raise Postgrex.Error, fn ->
          SQL.query!(
            Repo,
            ~s|CREATE UNIQUE INDEX CONCURRENTLY "#{index_name}" ON "#{table_name}" (value)|,
            []
          )
        end

        assert index_validity(index_name) == false

        drop_invalid = fn ->
          SQL.query!(Repo, ~s|DROP INDEX CONCURRENTLY IF EXISTS "#{index_name}"|, [])
        end

        create_index = fn ->
          SQL.query!(
            Repo,
            ~s|CREATE INDEX CONCURRENTLY IF NOT EXISTS "#{index_name}" ON "#{table_name}" (value)|,
            []
          )
        end

        assert :ok =
                 Repo.ensure_valid_concurrent_index!(
                   index_name,
                   drop_invalid,
                   create_index
                 )

        assert index_validity(index_name) == true

        original_oid = index_oid(index_name)

        assert :ok =
                 Repo.ensure_valid_concurrent_index!(
                   index_name,
                   drop_invalid,
                   create_index
                 )

        assert index_oid(index_name) == original_oid
      after
        SQL.query!(Repo, ~s|DROP TABLE IF EXISTS "#{table_name}" CASCADE|, [])
      end
    end)
  end

  test "rejects an unsafe index name before issuing SQL" do
    assert_raise ArgumentError, ~r/invalid concurrent index name/, fn ->
      Repo.ensure_valid_concurrent_index!(
        ~s(bad"; DROP TABLE users; --),
        fn -> raise "must not run" end,
        fn -> raise "must not run" end
      )
    end
  end

  defp index_validity(index_name) do
    %{rows: [[valid?]]} =
      SQL.query!(
        Repo,
        """
        SELECT index_record.indisvalid
        FROM pg_catalog.pg_index AS index_record
        JOIN pg_catalog.pg_class AS index_relation
          ON index_relation.oid = index_record.indexrelid
        WHERE index_relation.relname = $1
        """,
        [index_name]
      )

    valid?
  end

  defp index_oid(index_name) do
    %{rows: [[oid]]} =
      SQL.query!(
        Repo,
        """
        SELECT index_relation.oid
        FROM pg_catalog.pg_class AS index_relation
        JOIN pg_catalog.pg_namespace AS index_namespace
          ON index_namespace.oid = index_relation.relnamespace
        WHERE index_namespace.nspname = current_schema()
          AND index_relation.relname = $1
        """,
        [index_name]
      )

    oid
  end
end
