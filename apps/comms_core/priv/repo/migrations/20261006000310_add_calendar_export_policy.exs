defmodule CommsCore.Repo.Migrations.AddCalendarExportPolicy do
  use Ecto.Migration

  def up do
    alter table(:tenant_settings) do
      add(:allow_calendar_export, :boolean, null: false, default: false)
      add(:calendar_export_policy_version, :integer, null: false, default: 1)
    end

    create(
      constraint(:tenant_settings, :calendar_export_policy_version_positive,
        check: "calendar_export_policy_version > 0"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM oban_jobs
        WHERE worker IN ('CommsWorkers.CalendarSyncWorker', 'CommsWorkers.CalendarSyncReconcilerWorker')
          AND state::text IN ('available', 'scheduled', 'executing', 'retryable', 'suspended')
      ) THEN
        RAISE EXCEPTION 'calendar policy rollback blocked: active owner workers';
      END IF;
    END $$;
    """)

    # The public Calls inventory is checked before removing policy fields, so
    # a multi-step rollback cannot first commit a policy-only partial downgrade
    # and then discover retained Calendar state in the next migration.
    if CommsCore.AudioCalls.rollback_calendar_hazard_count() > 0,
      do: raise("calendar policy rollback blocked: retained owner state or policy")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM tenant_settings WHERE allow_calendar_export OR calendar_export_policy_version != 1) THEN
        RAISE EXCEPTION 'calendar rollback blocked: retained export policy';
      END IF;
    END $$;
    """)

    drop(constraint(:tenant_settings, :calendar_export_policy_version_positive))

    alter table(:tenant_settings) do
      remove(:allow_calendar_export)
      remove(:calendar_export_policy_version)
    end
  end
end
