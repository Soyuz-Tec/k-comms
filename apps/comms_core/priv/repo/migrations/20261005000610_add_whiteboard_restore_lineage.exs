defmodule CommsCore.Repo.Migrations.AddWhiteboardRestoreLineage do
  use Ecto.Migration

  def up do
    alter table(:whiteboard_operations) do
      add(:source_actor_user_ids, {:array, :binary_id}, null: false, default: [])
    end

    alter table(:whiteboard_versions) do
      add(:source_actor_user_ids, {:array, :binary_id}, null: false, default: [])
    end

    # The previous implementation did not record the restored checkpoint ID.
    # Preserve every possible original author conservatively for existing restores.
    execute("""
    UPDATE whiteboard_operations AS restored
    SET source_actor_user_ids = ARRAY(
      SELECT DISTINCT original.actor_user_id
      FROM whiteboard_operations AS original
      WHERE original.tenant_id = restored.tenant_id
        AND original.whiteboard_id = restored.whiteboard_id
        AND original.kind = 'scene.update'
      ORDER BY original.actor_user_id
    )
    WHERE restored.kind = 'scene.update'
      AND restored.client_operation_id LIKE 'restore-scene-%'
    """)

    execute("""
    UPDATE whiteboard_versions AS checkpoint
    SET source_actor_user_ids = ARRAY(
      SELECT DISTINCT original.actor_user_id
      FROM whiteboard_operations AS original
      WHERE original.tenant_id = checkpoint.tenant_id
        AND original.whiteboard_id = checkpoint.whiteboard_id
        AND original.sequence <= checkpoint.through_sequence
        AND original.kind = 'scene.update'
      ORDER BY original.actor_user_id
    )
    """)
  end

  def down do
    # A runtime without lineage cannot safely erase another author's restored
    # text. Remove dependent payloads and their caches before dropping metadata.
    execute("""
    DELETE FROM whiteboard_snapshots AS snapshot
    WHERE EXISTS (
      SELECT 1 FROM whiteboard_operations AS operation
      WHERE operation.tenant_id = snapshot.tenant_id
        AND operation.whiteboard_id = snapshot.whiteboard_id
        AND cardinality(operation.source_actor_user_ids) > 0
    )
    """)

    execute("""
    UPDATE whiteboard_operations
    SET payload = '{"elements":[]}'::jsonb
    WHERE kind = 'scene.update' AND cardinality(source_actor_user_ids) > 0
    """)

    execute("DELETE FROM whiteboard_versions WHERE cardinality(source_actor_user_ids) > 0")

    alter table(:whiteboard_versions) do
      remove(:source_actor_user_ids)
    end

    alter table(:whiteboard_operations) do
      remove(:source_actor_user_ids)
    end
  end
end
