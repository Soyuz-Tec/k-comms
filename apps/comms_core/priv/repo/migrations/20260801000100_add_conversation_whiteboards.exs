defmodule CommsCore.Repo.Migrations.AddConversationWhiteboards do
  use Ecto.Migration

  def up do
    create table(:whiteboards, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:sequence, :bigint, null: false, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:whiteboards, [:tenant_id, :id], name: :whiteboards_tenant_id_id_unique))

    create(
      unique_index(:whiteboards, [:tenant_id, :conversation_id],
        name: :whiteboards_tenant_conversation_unique
      )
    )

    create table(:whiteboard_operations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :whiteboard_id,
        references(:whiteboards, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:actor_user_id, references(:users, type: :binary_id), null: false)
      add(:actor_device_id, references(:devices, type: :binary_id), null: false)
      add(:client_operation_id, :text, null: false)
      add(:sequence, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(:whiteboard_operations, [:whiteboard_id, :sequence],
        name: :whiteboard_operations_board_sequence_unique
      )
    )

    create(
      unique_index(
        :whiteboard_operations,
        [:tenant_id, :actor_device_id, :conversation_id, :client_operation_id],
        name: :whiteboard_operations_idempotency_unique
      )
    )

    create(
      index(:whiteboard_operations, [:whiteboard_id, :sequence],
        name: :whiteboard_operations_clear_generation,
        where: "kind = 'board.clear'"
      )
    )

    create(
      constraint(:whiteboard_operations, :whiteboard_operations_valid_kind,
        check: "kind IN ('scene.update', 'board.clear')"
      )
    )

    create(
      constraint(:whiteboard_operations, :whiteboard_operations_positive_sequence,
        check: "sequence > 0"
      )
    )

    execute("""
    ALTER TABLE whiteboards
    ADD CONSTRAINT whiteboards_tenant_conversation_fk
    FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE whiteboard_operations
    ADD CONSTRAINT whiteboard_operations_tenant_board_fk
      FOREIGN KEY (tenant_id, whiteboard_id) REFERENCES whiteboards (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT whiteboard_operations_tenant_conversation_fk
      FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT whiteboard_operations_tenant_actor_fk
      FOREIGN KEY (tenant_id, actor_user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT whiteboard_operations_tenant_device_fk
      FOREIGN KEY (tenant_id, actor_device_id) REFERENCES devices (tenant_id, id)
    """)
  end

  def down do
    drop(table(:whiteboard_operations))
    drop(table(:whiteboards))
  end
end
