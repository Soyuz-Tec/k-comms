defmodule CommsCore.Repo.Migrations.IndexPendingDerivedErasureRepairs do
  use Ecto.Migration
  alias CommsCore.Repo
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Repo.ensure_valid_concurrent_index!(
      "deletion_requests_pending_derived_erasure_index",
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "DROP INDEX CONCURRENTLY IF EXISTS deletion_requests_pending_derived_erasure_index",
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS deletion_requests_pending_derived_erasure_index
          ON deletion_requests (completed_at, id)
          WHERE status = 'completed' AND coalesce(evidence->>'derived_erasure_version', '') != '1'
          """,
          []
        )
      end
    )
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP INDEX CONCURRENTLY IF EXISTS deletion_requests_pending_derived_erasure_index",
      []
    )
  end
end
