defmodule CommsCore.Repo.Migrations.AddConversationOnlyIdentityScope do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:access_scope, :text, null: false, default: "workspace")
    end

    execute("""
    UPDATE users
    SET access_scope = 'conversation_only'
    WHERE account_type = 'guest'
    """)

    create(
      constraint(:users, :users_access_scope_allowed,
        check: "access_scope IN ('workspace', 'conversation_only')"
      )
    )

    create(
      constraint(:users, :users_guest_access_scope_check,
        check: "account_type <> 'guest' OR access_scope = 'conversation_only'"
      )
    )

    create(
      constraint(:users, :users_conversation_only_account_type_check,
        check: "access_scope <> 'conversation_only' OR account_type IN ('human', 'guest')"
      )
    )

    create(
      index(:users, [:tenant_id, :access_scope, :status],
        name: :users_tenant_access_scope_status_index
      )
    )

    # Use wall-clock time for the 24-hour ceiling. PostgreSQL CURRENT_TIMESTAMP
    # is fixed at transaction start, while the rolling deadline is calculated
    # by the application after that transaction begins.
    execute("""
    CREATE OR REPLACE FUNCTION prevent_session_absolute_expiry_update()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.absolute_expires_at IS DISTINCT FROM OLD.absolute_expires_at THEN
        IF NOT (
          NEW.revoked_at IS NULL
          AND NEW.absolute_expires_at > OLD.absolute_expires_at
          AND NEW.absolute_expires_at <=
            (clock_timestamp() AT TIME ZONE 'UTC') + INTERVAL '24 hours'
          AND NEW.expires_at <= NEW.absolute_expires_at
          AND EXISTS (
            SELECT 1
            FROM users
            WHERE users.id = NEW.user_id
              AND users.tenant_id = NEW.tenant_id
              AND users.account_type = 'guest'
              AND users.access_scope = 'conversation_only'
              AND users.status = 'active'
              AND users.guest_expires_at = NEW.absolute_expires_at
          )
          AND EXISTS (
            SELECT 1
            FROM devices
            WHERE devices.id = NEW.device_id
              AND devices.user_id = NEW.user_id
              AND devices.tenant_id = NEW.tenant_id
              AND devices.revoked_at IS NULL
          )
        ) THEN
          RAISE EXCEPTION 'sessions.absolute_expires_at is immutable';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM users
        WHERE account_type = 'human'
          AND access_scope = 'conversation_only'
      ) THEN
        RAISE EXCEPTION
          'cannot remove users.access_scope while conversation-only human identities exist';
      END IF;
    END
    $$;
    """)

    drop(
      index(:users, [:tenant_id, :access_scope, :status],
        name: :users_tenant_access_scope_status_index
      )
    )

    drop(constraint(:users, :users_conversation_only_account_type_check))
    drop(constraint(:users, :users_guest_access_scope_check))
    drop(constraint(:users, :users_access_scope_allowed))

    execute("""
    CREATE OR REPLACE FUNCTION prevent_session_absolute_expiry_update()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.absolute_expires_at IS DISTINCT FROM OLD.absolute_expires_at THEN
        RAISE EXCEPTION 'sessions.absolute_expires_at is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    alter table(:users) do
      remove(:access_scope)
    end
  end
end
