defmodule CommsCore.Repo.Migrations.AddWhiteboardLibrary do
  use Ecto.Migration

  def up do
    alter table(:whiteboards) do
      add(:title, :text, null: false, default: "Untitled board")
      add(:library_version, :integer, null: false, default: 1)
      add(:title_actor_user_id, :binary_id)
    end

    create table(:whiteboard_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:whiteboard_id, references(:whiteboards, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:conversation_id, :binary_id, null: false)
      add(:actor_user_id, :binary_id, null: false)
      add(:label, :text, null: false)
      add(:through_sequence, :bigint, null: false)
      add(:elements, :map, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:whiteboard_versions, [:tenant_id, :whiteboard_id, :inserted_at]))

    create table(:whiteboard_assets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:whiteboard_id, references(:whiteboards, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:conversation_id, :binary_id, null: false)
      add(:attachment_id, :binary_id, null: false)
      add(:source_message_id, :binary_id, null: false)
      add(:actor_user_id, :binary_id, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:whiteboard_assets, [:whiteboard_id, :attachment_id]))

    execute(
      "ALTER TABLE whiteboard_versions ADD CONSTRAINT whiteboard_versions_tenant_board_fk FOREIGN KEY (tenant_id, whiteboard_id) REFERENCES whiteboards (tenant_id, id) ON DELETE CASCADE"
    )

    execute(
      "ALTER TABLE whiteboard_assets ADD CONSTRAINT whiteboard_assets_tenant_board_fk FOREIGN KEY (tenant_id, whiteboard_id) REFERENCES whiteboards (tenant_id, id) ON DELETE CASCADE"
    )
  end

  def down do
    drop(table(:whiteboard_assets))
    drop(table(:whiteboard_versions))

    alter table(:whiteboards) do
      remove(:title)
      remove(:library_version)
      remove(:title_actor_user_id)
    end
  end
end
