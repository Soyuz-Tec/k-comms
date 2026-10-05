defmodule CommsCore.Repo.Migrations.IndexResourceAuditHistory do
  use Ecto.Migration

  def up do
    create(
      index(:audit_events, [:tenant_id, :resource_type, :resource_id, :inserted_at, :id],
        name: :audit_events_resource_history_index
      )
    )

    create table(:audit_resource_history_snapshots, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:resource_type, :text, null: false)
      add(:resource_id, :binary_id, null: false)
      add(:actions, {:array, :text}, null: false)
      add(:origin_action, :text, null: false)
      add(:event_ids, {:array, :binary_id}, null: false)
      add(:truncated, :boolean, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(index(:audit_resource_history_snapshots, [:expires_at]))
    create(index(:audit_resource_history_snapshots, [:tenant_id, :expires_at]))

    create(
      constraint(:audit_resource_history_snapshots, :history_snapshot_members_bounded,
        check: "cardinality(event_ids) <= 5000 AND cardinality(actions) BETWEEN 1 AND 16"
      )
    )

    create(
      constraint(:audit_resource_history_snapshots, :history_snapshot_expiry_bounded,
        check: "expires_at = observed_at + interval '1 hour'"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM audit_resource_history_snapshots) THEN
        RAISE EXCEPTION 'audit history rollback refused: retained snapshots require owner expiry purge';
      END IF;
    END $$;
    """)

    drop(table(:audit_resource_history_snapshots))

    drop(
      index(:audit_events, [:tenant_id, :resource_type, :resource_id, :inserted_at, :id],
        name: :audit_events_resource_history_index
      )
    )
  end
end
