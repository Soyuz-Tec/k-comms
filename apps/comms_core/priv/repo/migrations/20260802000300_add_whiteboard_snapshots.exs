defmodule CommsCore.Repo.Migrations.AddWhiteboardSnapshots do
  use Ecto.Migration

  def up do
    # One materialised scene per board, so a joining client no longer replays
    # every operation since the last clear. Additive: older application images
    # ignore this table and keep replaying the full log, so roll-forward and
    # rollback both stay safe.
    create table(:whiteboard_snapshots, primary_key: false) do
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

      # Highest operation sequence folded into `elements`.
      add(:through_sequence, :bigint, null: false)
      # Sequence of the clear this snapshot is built on top of, so a snapshot
      # taken before a clear is never served for the generation after it.
      add(:generation_sequence, :bigint, null: false, default: 0)
      add(:elements, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:whiteboard_snapshots, [:whiteboard_id],
        name: :whiteboard_snapshots_board_unique
      )
    )

    create(
      unique_index(:whiteboard_snapshots, [:tenant_id, :id],
        name: :whiteboard_snapshots_tenant_id_unique
      )
    )

    create(
      constraint(:whiteboard_snapshots, :whiteboard_snapshots_positive_sequence,
        check: "through_sequence > 0"
      )
    )

    create(
      constraint(:whiteboard_snapshots, :whiteboard_snapshots_generation_within_reach,
        check: "generation_sequence <= through_sequence"
      )
    )

    execute("""
    ALTER TABLE whiteboard_snapshots
    ADD CONSTRAINT whiteboard_snapshots_tenant_board_fk
      FOREIGN KEY (tenant_id, whiteboard_id) REFERENCES whiteboards (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT whiteboard_snapshots_tenant_conversation_fk
      FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE CASCADE
    """)
  end

  def down do
    drop(table(:whiteboard_snapshots))
  end
end
