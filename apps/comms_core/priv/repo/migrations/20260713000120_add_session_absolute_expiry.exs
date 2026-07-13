defmodule CommsCore.Repo.Migrations.AddSessionAbsoluteExpiry do
  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add(:absolute_expires_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE sessions
    SET absolute_expires_at = inserted_at + INTERVAL '30 days'
    WHERE absolute_expires_at IS NULL
    """)

    alter table(:sessions) do
      modify(:absolute_expires_at, :utc_datetime_usec, null: false)
    end

    # Keep the immediately previous release able to create sessions during the
    # supported rollback window. Current writers always provide their
    # configured absolute deadline; this database default is only the
    # compatibility path for writers that predate the column.
    execute("""
    ALTER TABLE sessions
    ALTER COLUMN absolute_expires_at
    SET DEFAULT (
      (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '30 days'
    )
    """)

    create(index(:sessions, [:absolute_expires_at]))

    execute("""
    CREATE FUNCTION prevent_session_absolute_expiry_update()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.absolute_expires_at IS DISTINCT FROM OLD.absolute_expires_at THEN
        RAISE EXCEPTION 'sessions.absolute_expires_at is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER sessions_absolute_expiry_immutable
    BEFORE UPDATE OF absolute_expires_at ON sessions
    FOR EACH ROW EXECUTE FUNCTION prevent_session_absolute_expiry_update()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS sessions_absolute_expiry_immutable ON sessions")
    execute("DROP FUNCTION IF EXISTS prevent_session_absolute_expiry_update()")
    drop(index(:sessions, [:absolute_expires_at]))

    alter table(:sessions) do
      remove(:absolute_expires_at)
    end
  end
end
