defmodule CommsCore.Repo.Migrations.AddFileListingIndexes do
  use Ecto.Migration

  alias CommsCore.Repo

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Repo.ensure_valid_concurrent_index!(
      "messages_active_file_listing_cursor_index",
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s(DROP INDEX CONCURRENTLY IF EXISTS "messages_active_file_listing_cursor_index"),
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_active_file_listing_cursor_index
          ON messages (tenant_id, inserted_at, id)
          WHERE status = 'active'
          """,
          []
        )
      end
    )

    Repo.ensure_valid_concurrent_index!(
      "attachments_shared_by_owner_index",
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s(DROP INDEX CONCURRENTLY IF EXISTS "attachments_shared_by_owner_index"),
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS attachments_shared_by_owner_index
          ON attachments (tenant_id, owner_user_id, message_id)
          WHERE message_id IS NOT NULL AND status != 'deleted'
          """,
          []
        )
      end
    )
  end

  def down do
    execute(~s(DROP INDEX CONCURRENTLY IF EXISTS "attachments_shared_by_owner_index"))
    execute(~s(DROP INDEX CONCURRENTLY IF EXISTS "messages_active_file_listing_cursor_index"))
  end
end
