defmodule CommsCore.Repo.Migrations.AddOpaquePrivateEvents do
  use Ecto.Migration

  def up do
    create table(:opaque_private_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false)

      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:author_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:author_device_id, references(:devices, type: :uuid, on_delete: :restrict), null: false)

      add(:author_session_id, references(:sessions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:transaction_id, :text, null: false)
      add(:matrix_event_id, :text)
      add(:matrix_room_id, :text, null: false)
      add(:matrix_sender, :text, null: false)
      add(:membership_epoch, :bigint, null: false)
      add(:generation, :bigint, null: false)
      add(:sequence, :bigint, null: false)
      add(:input_fingerprint, :binary)
      add(:content, :map)
      add(:state, :text, null: false, default: "pending")
      add(:erased_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :opaque_private_events,
        [:tenant_id, :conversation_id, :author_session_id, :transaction_id],
        name: :opaque_private_event_idempotency
      )
    )

    create(unique_index(:opaque_private_events, [:tenant_id, :conversation_id, :sequence]))
    create(unique_index(:opaque_private_events, [:matrix_room_id, :matrix_event_id]))
    create(index(:opaque_private_events, [:tenant_id, :author_user_id]))

    create(
      constraint(:opaque_private_events, :opaque_private_event_state,
        check:
          "state IN ('pending','retained','erased') AND generation > 0 AND membership_epoch > 0 AND sequence > 0 AND (state <> 'erased' OR (content IS NULL AND input_fingerprint IS NULL)) AND (content IS NULL OR octet_length(content::text) <= 65536)"
      )
    )

    execute(
      "ALTER TABLE opaque_private_events ADD CONSTRAINT private_event_tenant_conversation_fk FOREIGN KEY (tenant_id,conversation_id) REFERENCES conversations(tenant_id,id), ADD CONSTRAINT private_event_author_device_fk FOREIGN KEY (tenant_id,author_user_id,author_device_id) REFERENCES devices(tenant_id,user_id,id), ADD CONSTRAINT private_event_author_session_fk FOREIGN KEY (tenant_id,author_user_id,author_device_id,author_session_id) REFERENCES sessions(tenant_id,user_id,device_id,id)",
      "SELECT 1"
    )
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM opaque_private_events) THEN RAISE EXCEPTION 'refusing retained opaque events, unknown sends or erasure tombstone rollback'; END IF; END $$"
    )

    drop(table(:opaque_private_events))
  end
end
