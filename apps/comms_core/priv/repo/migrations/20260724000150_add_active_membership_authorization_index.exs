defmodule CommsCore.Repo.Migrations.AddActiveMembershipAuthorizationIndex do
  use Ecto.Migration

  alias CommsCore.Repo

  @disable_ddl_transaction true
  @disable_migration_lock true
  @index_name "conversation_memberships_active_user_index"

  def up do
    Repo.ensure_valid_concurrent_index!(
      @index_name,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s(DROP INDEX CONCURRENTLY IF EXISTS "conversation_memberships_active_user_index"),
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_memberships_active_user_index
          ON conversation_memberships (tenant_id, user_id, conversation_id)
          WHERE left_at IS NULL
          """,
          []
        )
      end
    )
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Repo,
      ~s(DROP INDEX CONCURRENTLY IF EXISTS "conversation_memberships_active_user_index"),
      []
    )
  end
end
