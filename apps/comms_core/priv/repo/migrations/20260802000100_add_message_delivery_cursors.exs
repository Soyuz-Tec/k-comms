defmodule CommsCore.Repo.Migrations.AddMessageDeliveryCursors do
  use Ecto.Migration

  def up do
    create table(:message_delivery_cursors, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false)
      add(:delivered_sequence, :bigint, null: false, default: 0)
      add(:read_sequence, :bigint, null: false, default: 0)
      add(:delivered_at, :utc_datetime_usec)
      add(:read_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:message_delivery_cursors, [:tenant_id, :conversation_id, :user_id, :device_id],
        name: :message_delivery_cursors_identity_unique
      )
    )

    create(
      index(:message_delivery_cursors, [:tenant_id, :conversation_id, :delivered_sequence],
        name: :message_delivery_cursors_delivered_sequence_index
      )
    )

    create(
      index(:message_delivery_cursors, [:tenant_id, :conversation_id, :read_sequence],
        name: :message_delivery_cursors_read_sequence_index
      )
    )

    create(
      constraint(:message_delivery_cursors, :message_delivery_cursors_valid_sequences,
        check:
          "delivered_sequence >= 0 AND read_sequence >= 0 AND read_sequence <= delivered_sequence"
      )
    )

    execute("""
    ALTER TABLE message_delivery_cursors
    ADD CONSTRAINT message_delivery_cursors_tenant_conversation_fk
    FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT message_delivery_cursors_tenant_user_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT message_delivery_cursors_tenant_device_fk
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id) ON DELETE CASCADE
    """)

  end

  def down do
    drop(table(:message_delivery_cursors))
  end
end
