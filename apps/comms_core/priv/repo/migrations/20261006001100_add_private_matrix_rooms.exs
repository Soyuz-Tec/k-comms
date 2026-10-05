defmodule CommsCore.Repo.Migrations.AddPrivateMatrixRooms do
  use Ecto.Migration

  def up do
    alter(table(:conversations),
      do: add(:content_mode, :text, null: false, default: "server_readable")
    )

    create(
      constraint(:conversations, :conversation_content_mode,
        check: "content_mode IN ('server_readable','matrix_e2ee')"
      )
    )

    create table(:private_matrix_rooms, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false)

      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:creator_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:matrix_room_id, :text)
      add(:room_alias, :text, null: false)
      add(:provider_issuer, :text, null: false)
      add(:provider_server_name, :text, null: false)
      add(:control_matrix_user_id, :text, null: false)
      add(:provisioning_attempted_at, :utc_datetime_usec)
      add(:pending_removed_matrix_user_ids, {:array, :text}, null: false, default: [])
      add(:input_fingerprint, :binary, null: false)
      add(:historical_user_ids, {:array, :uuid}, null: false)
      add(:matrix_members, :map, null: false, default: %{})
      add(:state, :text, null: false, default: "provisioning")
      add(:membership_epoch, :bigint, null: false, default: 1)
      add(:generation, :bigint, null: false, default: 1)
      add(:purge_id, :text)
      add(:pending_removed_matrix_user_id, :text)
      add(:provider_purged_at, :utc_datetime_usec)
      add(:key_cleanup_state, :text, null: false, default: "unconfirmed")
      add(:control_claim_id, :uuid)
      add(:control_claim_expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:private_matrix_rooms, [:tenant_id, :conversation_id]))
    create(unique_index(:private_matrix_rooms, [:room_alias]))
    create(unique_index(:private_matrix_rooms, [:matrix_room_id]))

    create(
      constraint(:private_matrix_rooms, :private_room_state,
        check:
          "state IN ('provisioning','active','rekey_pending','purge_pending','provider_purged','erased') AND generation > 0 AND membership_epoch > 0 AND cardinality(historical_user_ids) BETWEEN 1 AND 100 AND key_cleanup_state = 'unconfirmed' AND state <> 'erased'"
      )
    )

    execute(
      "ALTER TABLE private_matrix_rooms ADD CONSTRAINT private_room_tenant_conversation_fk FOREIGN KEY (tenant_id,conversation_id) REFERENCES conversations(tenant_id,id), ADD CONSTRAINT private_room_tenant_creator_fk FOREIGN KEY (tenant_id,creator_user_id) REFERENCES users(tenant_id,id)",
      "SELECT 1"
    )
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM private_matrix_rooms) OR EXISTS (SELECT 1 FROM conversations WHERE content_mode = 'matrix_e2ee') THEN RAISE EXCEPTION 'refusing retained private room lineage, provider purge or key cleanup proof rollback'; END IF; END $$"
    )

    drop(table(:private_matrix_rooms))
    drop(constraint(:conversations, :conversation_content_mode))
    alter(table(:conversations), do: remove(:content_mode))
  end
end
