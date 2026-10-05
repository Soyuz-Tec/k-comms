defmodule CommsCore.Repo.Migrations.AddPrivateMemberWorkspaces do
  use Ecto.Migration

  def up do
    create table(:member_workspaces, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:contact_ids, {:array, :binary_id}, null: false, default: [])
      add(:contact_groups, :map, null: false, default: %{"items" => []})
      add(:profile_reviewed_at, :utc_datetime_usec)
      add(:onboarding_dismissed_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:member_workspaces, [:tenant_id, :user_id]))

    execute("""
    ALTER TABLE member_workspaces ADD CONSTRAINT member_workspaces_tenant_user_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users(tenant_id, id) ON DELETE CASCADE
    """)

    create(
      constraint(:member_workspaces, :member_workspaces_contact_limit,
        check: "cardinality(contact_ids) <= 500"
      )
    )

    create(
      constraint(:member_workspaces, :member_workspaces_group_shape,
        check:
          "jsonb_typeof(contact_groups->'items') = 'array' AND jsonb_array_length(contact_groups->'items') <= 20 AND octet_length(contact_groups::text) <= 65536"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM member_workspaces) THEN
        RAISE EXCEPTION 'Private member state requires a compatible binary or verified owner erasure';
      END IF;
    END $$
    """)

    drop(table(:member_workspaces))
  end
end
