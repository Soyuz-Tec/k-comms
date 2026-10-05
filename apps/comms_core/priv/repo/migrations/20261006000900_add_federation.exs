defmodule CommsCore.Repo.Migrations.AddFederation do
  use Ecto.Migration

  def up do
    create table(:federation_trusts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:domain, :string, null: false)
      add(:residency, :string, null: false)
      add(:cross_border_reason, :string, null: false)
      add(:enabled, :boolean, default: false, null: false)
      add(:lock_version, :integer, default: 1, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:federation_trusts, [:tenant_id]))
    create(unique_index(:federation_trusts, [:id, :tenant_id]))

    create table(:federation_rooms, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:conversation_id, :binary_id, null: false)

      add(
        :trust_id,
        references(:federation_trusts,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(:created_by_user_id, :binary_id)
      add(:alias_localpart, :string, null: false)
      add(:provider_issuer, :string, null: false)
      add(:provider_server_name, :string, null: false)
      add(:provider_room_box, :binary)
      add(:status, :string, default: "creating", null: false)
      add(:generation, :integer, default: 1, null: false)
      add(:lock_version, :integer, default: 1, null: false)
      add(:fenced_at, :utc_datetime_usec)
      add(:remote_cleanup_state, :string, default: "none")
      add(:local_cleanup_confirmed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:federation_rooms, [:tenant_id]))
    create(unique_index(:federation_rooms, [:id, :tenant_id]))

    create table(:federation_participants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :room_id,
        references(:federation_rooms,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(:user_id, :binary_id)
      add(:principal_hash, :string, null: false)
      add(:principal_box, :binary)
      add(:consent_status, :string, default: "invited", null: false)
      add(:lock_version, :integer, default: 1, null: false)
      add(:joined_observed_at, :utc_datetime_usec)
      add(:withdrawn_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:federation_participants, [:tenant_id]))

    create table(:federation_commands, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :room_id,
        references(:federation_rooms,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(:user_id, :binary_id)
      add(:device_id, :binary_id)
      add(:session_id, :binary_id)
      add(:request_key, :string, null: false)
      add(:payload_digest, :string, null: false)
      add(:target_receipt_id, :binary_id)
      add(:kind, :string, null: false)
      add(:payload_box, :binary)
      add(:status, :string, default: "pending", null: false)
      add(:generation, :integer, null: false)
      add(:expected_room_version, :integer)
      add(:attempts, :integer, default: 0)
      add(:last_error, :string)
      add(:provider_receipt_box, :binary)
      add(:expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:federation_commands, [:tenant_id]))
    create(unique_index(:federation_commands, [:id, :tenant_id]))

    create table(:federation_event_receipts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)

      add(
        :room_id,
        references(:federation_rooms,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :command_id,
        references(:federation_commands,
          type: :binary_id,
          with: [tenant_id: :tenant_id],
          on_delete: :restrict
        )
      )

      add(:event_hash, :string, null: false)
      add(:provider_event_box, :binary)
      add(:sender_hash, :string)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:redacted_observed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:federation_event_receipts, [:tenant_id]))
    create(unique_index(:federation_commands, [:tenant_id, :room_id, :request_key]))
    create(unique_index(:federation_trusts, [:tenant_id, :domain]))
    create(unique_index(:federation_rooms, [:tenant_id, :conversation_id]))
    create(unique_index(:federation_rooms, [:alias_localpart]))
    create(unique_index(:federation_participants, [:tenant_id, :room_id, :principal_hash]))
    create(unique_index(:federation_event_receipts, [:tenant_id, :room_id, :event_hash]))

    create(
      constraint(:federation_trusts, :federation_trust_version_positive,
        check: "lock_version > 0"
      )
    )

    create(
      constraint(:federation_rooms, :federation_room_version_positive,
        check: "generation > 0 AND lock_version > 0"
      )
    )

    create(
      constraint(:federation_participants, :federation_participant_version_positive,
        check: "lock_version > 0"
      )
    )
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM federation_trusts) OR EXISTS (SELECT 1 FROM federation_rooms) OR EXISTS (SELECT 1 FROM federation_participants) OR EXISTS (SELECT 1 FROM federation_commands) OR EXISTS (SELECT 1 FROM federation_event_receipts) THEN RAISE EXCEPTION 'Federation rollback refused: retained consent, mappings, commands or deletion uncertainty'; END IF; END $$"
    )

    drop(table(:federation_event_receipts))
    drop(table(:federation_commands))
    drop(table(:federation_participants))
    drop(table(:federation_rooms))
    drop(table(:federation_trusts))
  end
end
