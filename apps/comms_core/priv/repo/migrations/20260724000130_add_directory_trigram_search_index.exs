defmodule CommsCore.Repo.Migrations.AddDirectoryTrigramSearchIndex do
  use Ecto.Migration

  alias CommsCore.Repo
  @disable_ddl_transaction true
  @disable_migration_lock true
  @index_name "users_active_human_display_name_trgm_index"

  def up do
    Ecto.Adapters.SQL.query!(Repo, "CREATE EXTENSION IF NOT EXISTS pg_trgm", [])

    Repo.ensure_valid_concurrent_index!(
      @index_name,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s(DROP INDEX CONCURRENTLY IF EXISTS "users_active_human_display_name_trgm_index"),
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS users_active_human_display_name_trgm_index
          ON users USING GIN (display_name gin_trgm_ops)
          WHERE status = 'active' AND account_type = 'human'
          """,
          []
        )
      end
    )
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Repo,
      ~s(DROP INDEX CONCURRENTLY IF EXISTS "users_active_human_display_name_trgm_index"),
      []
    )
  end
end
