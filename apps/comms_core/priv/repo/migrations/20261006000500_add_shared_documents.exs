defmodule CommsCore.Repo.Migrations.AddSharedDocuments do
  use Ecto.Migration

  def up do
    create table(:shared_documents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :uuid, null: false)
      add(:conversation_id, :uuid, null: false)
      add(:created_by_user_id, :uuid)
      add(:created_by_device_id, :uuid)
      add(:client_document_id, :uuid, null: false)
      add(:title, :text, null: false)
      add(:content, :text, null: false, default: "")
      add(:atoms, {:array, :map}, null: false, default: [])
      add(:author_user_ids, {:array, :uuid}, null: false, default: [])
      add(:lineage_verified, :boolean, null: false, default: true)
      add(:generation, :bigint, null: false, default: 1)
      add(:version, :bigint, null: false, default: 0)
      add(:retained_operation_bytes, :bigint, null: false, default: 0)
      add(:erased_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:shared_documents, [:tenant_id, :conversation_id, :client_document_id],
        name: :shared_documents_client_id_unique
      )
    )

    create(index(:shared_documents, [:tenant_id, :conversation_id, :erased_at]))
    create(index(:shared_documents, [:author_user_ids], using: :gin))

    create(
      constraint(:shared_documents, :shared_documents_bounds,
        check:
          "version >= 0 AND generation >= 1 AND retained_operation_bytes BETWEEN 0 AND 16777216 AND octet_length(content) <= 65536 AND cardinality(atoms) <= 32000 AND cardinality(author_user_ids) <= 250"
      )
    )

    execute(
      "ALTER TABLE shared_documents ADD CONSTRAINT shared_documents_conversation_tenant_fk FOREIGN KEY (conversation_id, tenant_id) REFERENCES conversations(id, tenant_id)"
    )

    create table(:shared_document_operations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :uuid, null: false)
      add(:conversation_id, :uuid, null: false)

      add(:document_id, references(:shared_documents, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:actor_user_id, :uuid, null: false)
      add(:actor_device_id, :uuid, null: false)
      add(:client_operation_id, :uuid, null: false)
      add(:generation, :bigint, null: false)
      add(:version, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:input, :map, null: false)
      add(:payload, :map, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(:shared_document_operations, [:document_id, :client_operation_id],
        name: :shared_document_operations_client_id_unique
      )
    )

    create(
      unique_index(:shared_document_operations, [:document_id, :version],
        name: :shared_document_operations_version_unique
      )
    )

    create(index(:shared_document_operations, [:tenant_id, :conversation_id, :document_id]))

    create(
      constraint(:shared_document_operations, :shared_document_operations_bounds,
        check: "generation >= 1 AND version >= 1 AND kind IN ('create', 'edit', 'rename', 'copy')"
      )
    )
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM shared_documents) OR EXISTS (SELECT 1 FROM shared_document_operations) THEN RAISE EXCEPTION 'shared documents rollback refused: retained document or operation rows'; END IF; END $$"
    )

    drop(table(:shared_document_operations))
    drop(table(:shared_documents))
  end
end
