defmodule CommsCore.Repo.Migrations.AddRetentionExclusionIndex do
  use Ecto.Migration

  alias CommsCore.Repo

  @disable_ddl_transaction true
  @disable_migration_lock true
  @index_name "deletion_requests_retention_exclusion_index"

  def up do
    Repo.ensure_valid_concurrent_index!(
      @index_name,
      fn -> Ecto.Adapters.SQL.query!(Repo,
        "DROP INDEX CONCURRENTLY IF EXISTS deletion_requests_retention_exclusion_index", []) end,
      fn -> Ecto.Adapters.SQL.query!(Repo, """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS deletion_requests_retention_exclusion_index
        ON deletion_requests (tenant_id, message_id)
        WHERE target_type = 'message'
          AND status IN ('pending', 'approved', 'in_progress', 'completed')
        """, []) end
    )
  end

  def down do
    Ecto.Adapters.SQL.query!(Repo,
      "DROP INDEX CONCURRENTLY IF EXISTS deletion_requests_retention_exclusion_index", [])
  end
end
