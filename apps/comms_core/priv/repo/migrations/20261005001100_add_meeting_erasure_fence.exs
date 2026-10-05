defmodule CommsCore.Repo.Migrations.AddMeetingErasureFence do
  use Ecto.Migration

  def up do
    alter table(:meetings) do
      modify :host_user_id, :binary_id, null: true
      add :author_user_ids, {:array, :binary_id}, null: false, default: []
      add :author_lineage_complete, :boolean, null: false, default: false
      add :erasure_requested_at, :utc_datetime_usec
      add :erased_at, :utc_datetime_usec
      add :erasure_user_fingerprint, :binary
    end
    create index(:meetings, [:tenant_id, :erasure_user_fingerprint])
    create index(:meetings, [:tenant_id], where: "author_lineage_complete = false")
    create constraint(:meetings, :meetings_erasure_state_consistent,
      check: "erased_at IS NULL OR (erasure_requested_at IS NOT NULL AND status = 'cancelled' AND host_user_id IS NULL AND cardinality(author_user_ids) = 0)")
  end

  def down do
    # Never reconstruct an erased identity or drop its verification evidence.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM meetings WHERE host_user_id IS NULL OR erasure_requested_at IS NOT NULL OR erased_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Meeting erasure tombstones require roll-forward; refusing to remove the erasure fence or restore host identities';
      END IF;
    END $$;
    """)
    drop constraint(:meetings, :meetings_erasure_state_consistent)
    drop index(:meetings, [:tenant_id, :erasure_user_fingerprint])
    drop index(:meetings, [:tenant_id], where: "author_lineage_complete = false")
    alter table(:meetings) do
      remove :erasure_user_fingerprint
      remove :erased_at
      remove :erasure_requested_at
      remove :author_lineage_complete
      remove :author_user_ids
      modify :host_user_id, :binary_id, null: false
    end
  end
end
