defmodule CommsCore.Repo.Migrations.AddCallSessionListingIndexes do
  use Ecto.Migration

  alias CommsCore.Repo

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Repo.ensure_valid_concurrent_index!(
      "audio_calls_active_session_cursor_index",
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s(DROP INDEX CONCURRENTLY IF EXISTS "audio_calls_active_session_cursor_index"),
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS audio_calls_active_session_cursor_index
          ON audio_calls (tenant_id, started_at, id)
          WHERE status IN ('active', 'ending')
          """,
          []
        )
      end
    )

    Repo.ensure_valid_concurrent_index!(
      "audio_calls_recent_session_cursor_index",
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s(DROP INDEX CONCURRENTLY IF EXISTS "audio_calls_recent_session_cursor_index"),
          []
        )
      end,
      fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS audio_calls_recent_session_cursor_index
          ON audio_calls (tenant_id, started_at, id)
          WHERE status = 'ended'
          """,
          []
        )
      end
    )
  end

  def down do
    execute(~s(DROP INDEX CONCURRENTLY IF EXISTS "audio_calls_recent_session_cursor_index"))
    execute(~s(DROP INDEX CONCURRENTLY IF EXISTS "audio_calls_active_session_cursor_index"))
  end
end
