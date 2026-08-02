defmodule CommsCore.Repo.Migrations.RepairSessionAbsoluteExpiryWallClock do
  use Ecto.Migration

  @moduledoc """
  Reinstalls the session absolute-expiry guard with a wall-clock ceiling.

  The guest-authority migration originally used `CURRENT_TIMESTAMP`, which is
  fixed when a PostgreSQL transaction starts. Instant-room authority deadlines
  are calculated after that point, so a valid 24-hour extension can be a few
  milliseconds beyond the trigger's fixed ceiling. Existing databases need a
  forward migration because editing an already-applied migration cannot repair
  the installed function.
  """

  def up do
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
    CREATE OR REPLACE FUNCTION prevent_session_absolute_expiry_update()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.absolute_expires_at IS DISTINCT FROM OLD.absolute_expires_at THEN
        IF NOT (
          NEW.revoked_at IS NULL
          AND NEW.absolute_expires_at > OLD.absolute_expires_at
          AND NEW.absolute_expires_at <=
            (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '24 hours'
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
end
