defmodule CommsCore.Repo.Migrations.AddActiveHumanDirectoryIndex do
  use Ecto.Migration

  alias CommsCore.Repo

  @disable_ddl_transaction true
  @disable_migration_lock true
  @index_name "users_active_human_directory_index"

  def up do
    Repo.ensure_valid_concurrent_index!(
      @index_name,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s(DROP INDEX CONCURRENTLY IF EXISTS "users_active_human_directory_index"),
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS users_active_human_directory_index
          ON users (tenant_id, lower(display_name), id)
          WHERE status = 'active' AND account_type = 'human'
          """,
          []
        )
      end
    )
  end

  def down do
    execute(~s(DROP INDEX CONCURRENTLY IF EXISTS "users_active_human_directory_index"))
  end
end
