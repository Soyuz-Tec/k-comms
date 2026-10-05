defmodule CommsCore.Repo.Migrations.AddCalendarSync do
  use Ecto.Migration

  def up do
    create table(:calendar_connections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :user_id,
        references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
        null: false
      )

      add(:provider, :string, null: false)
      add(:status, :string, null: false, default: "awaiting_consent")
      add(:version, :integer, null: false, default: 1)
      add(:consent_generation, :integer, null: false, default: 1)
      add(:credential_generation, :integer, null: false, default: 1)
      add(:export_policy_version, :integer, null: false)
      add(:credentials_box, :map)
      add(:external_identity_box, :map)
      add(:access_expires_at, :utc_datetime_usec)
      add(:fenced_at, :utc_datetime_usec)
      add(:credential_destroyed_at, :utc_datetime_usec)
      add(:provider_grant_revocation, :string, null: false, default: "not_requested")
      add(:last_success_at, :utc_datetime_usec)
      add(:safe_reason, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_connections, [:tenant_id, :id]))
    create(unique_index(:calendar_connections, [:tenant_id, :id, :user_id]))
    create(unique_index(:calendar_connections, [:tenant_id, :id, :user_id, :provider]))
    create(unique_index(:calendar_connections, [:tenant_id, :user_id, :provider]))

    create(
      constraint(:calendar_connections, :calendar_connection_state,
        check:
          "provider IN ('google','microsoft') AND status IN ('awaiting_consent','ready','reauthorization_required','removing','held_cleanup_blocked','removed') AND provider_grant_revocation IN ('not_requested','pending','confirmed','external_unconfirmed','failed') AND version > 0 AND consent_generation > 0 AND credential_generation > 0 AND export_policy_version > 0"
      )
    )

    create(
      constraint(:calendar_connections, :calendar_connection_box_bounds,
        check:
          "(credentials_box IS NULL OR octet_length(credentials_box::text) <= 131072) AND (external_identity_box IS NULL OR octet_length(external_identity_box::text) <= 16384)"
      )
    )

    create(
      constraint(:calendar_connections, :calendar_connection_ready_credentials,
        check:
          "status <> 'ready' OR (credentials_box IS NOT NULL AND external_identity_box IS NOT NULL AND access_expires_at IS NOT NULL AND fenced_at IS NULL)"
      )
    )

    create(
      constraint(:calendar_connections, :calendar_connection_removed_credentials,
        check:
          "status <> 'removed' OR (credentials_box IS NULL AND external_identity_box IS NULL AND credential_destroyed_at IS NOT NULL AND fenced_at IS NOT NULL)"
      )
    )

    create table(:calendar_oauth_challenges, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :connection_id,
        references(:calendar_connections,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :user_id,
        references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
        null: false
      )

      add(:device_id, :binary_id, null: false)
      add(:session_id, :binary_id, null: false)
      add(:provider, :string, null: false)
      add(:state_hash, :binary, null: false)
      add(:binding_hash, :binary, null: false)
      add(:challenge_box, :map, null: false)
      add(:consent_generation, :integer, null: false)
      add(:export_policy_version, :integer, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:terminal_reason, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_oauth_challenges, [:state_hash]))
    create(index(:calendar_oauth_challenges, [:tenant_id, :user_id, :expires_at]))

    create(
      constraint(:calendar_oauth_challenges, :calendar_challenge_bounds,
        check:
          "octet_length(state_hash) = 32 AND octet_length(binding_hash) = 32 AND octet_length(challenge_box::text) <= 16384 AND provider IN ('google','microsoft') AND consent_generation > 0 AND export_policy_version > 0 AND expires_at > inserted_at AND expires_at <= inserted_at + interval '5 minutes'"
      )
    )

    execute(
      "ALTER TABLE calendar_oauth_challenges ADD CONSTRAINT calendar_challenge_connection_owner FOREIGN KEY (tenant_id,connection_id,user_id,provider) REFERENCES calendar_connections(tenant_id,id,user_id,provider) ON DELETE RESTRICT"
    )

    create table(:calendar_exports, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :connection_id,
        references(:calendar_connections,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :user_id,
        references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
        null: false
      )

      add(
        :meeting_id,
        references(:meetings,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(:conversation_id, :binary_id, null: false)
      add(:consent_generation, :integer, null: false)
      add(:sync_generation, :integer, null: false, default: 1)
      add(:version, :integer, null: false, default: 1)
      add(:desired_meeting_version, :integer, null: false)
      add(:applied_meeting_version, :integer)
      add(:status, :string, null: false, default: "pending")
      add(:safe_reason, :string)
      add(:author_user_ids, {:array, :binary_id}, null: false)
      add(:author_lineage_complete, :boolean, null: false, default: false)
      add(:tombstoned_at, :utc_datetime_usec)
      add(:removed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_exports, [:tenant_id, :id]))
    create(unique_index(:calendar_exports, [:tenant_id, :id, :connection_id, :meeting_id]))
    create(unique_index(:calendar_exports, [:connection_id, :meeting_id, :consent_generation]))
    create(index(:calendar_exports, [:tenant_id, :conversation_id, :id]))

    execute(
      "CREATE INDEX calendar_exports_author_lineage ON calendar_exports USING gin(author_user_ids)"
    )

    create(
      constraint(:calendar_exports, :calendar_export_state,
        check:
          "consent_generation > 0 AND sync_generation > 0 AND version > 0 AND desired_meeting_version > 0 AND (applied_meeting_version IS NULL OR applied_meeting_version BETWEEN 1 AND desired_meeting_version) AND cardinality(author_user_ids) BETWEEN 1 AND 5000 AND status IN ('pending','synced','conflict','stopping','removed','blocked','failed','uncertain') AND (status <> 'removed' OR (tombstoned_at IS NOT NULL AND removed_at IS NOT NULL))"
      )
    )

    execute(
      "ALTER TABLE calendar_exports ADD CONSTRAINT calendar_export_connection_owner FOREIGN KEY (tenant_id,connection_id,user_id) REFERENCES calendar_connections(tenant_id,id,user_id) ON DELETE RESTRICT"
    )

    create table(:calendar_event_mappings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :connection_id,
        references(:calendar_connections,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :export_id,
        references(:calendar_exports,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(:meeting_id, :binary_id, null: false)
      add(:occurrence_sequence, :integer, null: false)
      add(:consent_generation, :integer, null: false)
      add(:sync_generation, :integer, null: false)
      add(:desired_meeting_version, :integer, null: false)
      add(:applied_meeting_version, :integer)
      add(:status, :string, null: false, default: "unknown")
      add(:external_identity_box, :map)
      add(:etag_box, :map)
      add(:duplicate_identities_box, :map)
      add(:tombstoned_at, :utc_datetime_usec)
      add(:verified_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_event_mappings, [:tenant_id, :id]))
    create(unique_index(:calendar_event_mappings, [:tenant_id, :id, :connection_id, :export_id]))

    create(
      unique_index(:calendar_event_mappings, [:export_id, :sync_generation, :occurrence_sequence])
    )

    create(index(:calendar_event_mappings, [:tenant_id, :connection_id, :status]))

    create(
      constraint(:calendar_event_mappings, :calendar_mapping_state,
        check:
          "occurrence_sequence BETWEEN 1 AND 52 AND consent_generation > 0 AND sync_generation > 0 AND desired_meeting_version > 0 AND (applied_meeting_version IS NULL OR applied_meeting_version BETWEEN 1 AND desired_meeting_version) AND status IN ('unknown','present','absent','conflict','removing')"
      )
    )

    create(
      constraint(:calendar_event_mappings, :calendar_mapping_box_bounds,
        check:
          "(external_identity_box IS NULL OR octet_length(external_identity_box::text) <= 16384) AND (etag_box IS NULL OR octet_length(etag_box::text) <= 8192) AND (duplicate_identities_box IS NULL OR octet_length(duplicate_identities_box::text) <= 16384)"
      )
    )

    execute(
      "ALTER TABLE calendar_event_mappings ADD CONSTRAINT calendar_mapping_export_owner FOREIGN KEY (tenant_id,export_id,connection_id,meeting_id) REFERENCES calendar_exports(tenant_id,id,connection_id,meeting_id) ON DELETE RESTRICT"
    )

    create table(:calendar_sync_commands, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :connection_id,
        references(:calendar_connections,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :export_id,
        references(:calendar_exports,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        )
      )

      add(
        :mapping_id,
        references(:calendar_event_mappings,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        )
      )

      add(:operation, :string, null: false)
      add(:consent_generation, :integer, null: false)
      add(:credential_generation, :integer, null: false)
      add(:sync_generation, :integer)
      add(:meeting_version, :integer)
      add(:status, :string, null: false, default: "queued")
      add(:attempt, :integer, null: false, default: 0)
      add(:lease_id, :binary_id)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:available_at, :utc_datetime_usec, null: false)
      add(:safe_reason, :string)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :calendar_sync_commands,
        [
          :mapping_id,
          :operation,
          :meeting_version,
          :sync_generation,
          :consent_generation,
          :credential_generation
        ],
        where: "mapping_id IS NOT NULL"
      )
    )

    create(
      unique_index(
        :calendar_sync_commands,
        [:connection_id, :operation, :consent_generation, :credential_generation],
        where: "mapping_id IS NULL"
      )
    )

    create(index(:calendar_sync_commands, [:status, :available_at, :id]))

    create(
      constraint(:calendar_sync_commands, :calendar_command_state,
        check:
          "operation IN ('create','update','delete','verify_absence','reconcile','refresh','revoke','destroy') AND consent_generation > 0 AND credential_generation > 0 AND attempt BETWEEN 0 AND 20 AND status IN ('queued','leased','uncertain','retryable','blocked','done','failed') AND (sync_generation IS NULL OR sync_generation > 0) AND (meeting_version IS NULL OR meeting_version > 0) AND (status <> 'leased' OR (lease_id IS NOT NULL AND lease_expires_at IS NOT NULL)) AND (status <> 'done' OR completed_at IS NOT NULL)"
      )
    )

    create(
      constraint(:calendar_sync_commands, :calendar_command_mapping_scope,
        check:
          "mapping_id IS NULL OR (export_id IS NOT NULL AND sync_generation IS NOT NULL AND meeting_version IS NOT NULL)"
      )
    )

    execute(
      "ALTER TABLE calendar_sync_commands ADD CONSTRAINT calendar_command_mapping_owner FOREIGN KEY (tenant_id,mapping_id,connection_id,export_id) REFERENCES calendar_event_mappings(tenant_id,id,connection_id,export_id) ON DELETE RESTRICT"
    )

    create table(:calendar_erasure_receipts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:target_type, :string, null: false)
      add(:target_fingerprint, :binary, null: false)
      add(:version, :integer, null: false, default: 1)
      add(:status, :string, null: false, default: "pending")
      add(:removed_event_count, :integer, null: false, default: 0)
      add(:destroyed_credential_count, :integer, null: false, default: 0)
      add(:verified_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:calendar_erasure_receipts, [:tenant_id, :target_type, :target_fingerprint])
    )

    create(
      constraint(:calendar_erasure_receipts, :calendar_erasure_receipt_state,
        check:
          "target_type IN ('user','conversation','message') AND octet_length(target_fingerprint) = 32 AND version > 0 AND status IN ('pending','held','verified') AND removed_event_count >= 0 AND destroyed_credential_count >= 0 AND (status <> 'verified' OR verified_at IS NOT NULL)"
      )
    )

    execute("""
    CREATE FUNCTION calendar_preserve_fence() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.tombstoned_at IS NOT NULL AND NEW.tombstoned_at IS DISTINCT FROM OLD.tombstoned_at THEN
        RAISE EXCEPTION 'calendar tombstone is immutable' USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.desired_meeting_version < OLD.desired_meeting_version THEN
        RAISE EXCEPTION 'calendar source version cannot decrease' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute(
      "CREATE TRIGGER calendar_export_monotonic_fence BEFORE UPDATE ON calendar_exports FOR EACH ROW EXECUTE FUNCTION calendar_preserve_fence()"
    )

    execute(
      "CREATE TRIGGER calendar_mapping_monotonic_fence BEFORE UPDATE ON calendar_event_mappings FOR EACH ROW EXECUTE FUNCTION calendar_preserve_fence()"
    )
  end

  def down do
    # An old application cannot clean managed provider objects or decrypt their
    # dedicated retained material. Refuse before any DDL when state remains.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM calendar_connections LIMIT 1) THEN
        RAISE EXCEPTION 'calendar rollback blocked: retained owner state';
      END IF;
      IF EXISTS (SELECT 1 FROM calendar_oauth_challenges LIMIT 1) THEN
        RAISE EXCEPTION 'calendar rollback blocked: retained owner state';
      END IF;
      IF EXISTS (SELECT 1 FROM calendar_exports LIMIT 1) THEN
        RAISE EXCEPTION 'calendar rollback blocked: retained owner state';
      END IF;
      IF EXISTS (SELECT 1 FROM calendar_event_mappings LIMIT 1) THEN
        RAISE EXCEPTION 'calendar rollback blocked: retained owner state';
      END IF;
      IF EXISTS (SELECT 1 FROM calendar_sync_commands LIMIT 1) THEN
        RAISE EXCEPTION 'calendar rollback blocked: retained owner state';
      END IF;
      IF EXISTS (SELECT 1 FROM calendar_erasure_receipts LIMIT 1) THEN
        RAISE EXCEPTION 'calendar rollback blocked: retained owner state';
      END IF;
    END $$;
    """)

    drop(table(:calendar_erasure_receipts))
    drop(table(:calendar_sync_commands))
    drop(table(:calendar_event_mappings))
    drop(table(:calendar_exports))
    drop(table(:calendar_oauth_challenges))
    drop(table(:calendar_connections))
    execute("DROP FUNCTION calendar_preserve_fence()")
  end
end
