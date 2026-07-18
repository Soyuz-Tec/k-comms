defmodule CommsCore.Repo.Migrations.AddExpiringPlatformRoleGrants do
  use Ecto.Migration

  def up do
    create table(:platform_role_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:role, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:platform_role_grants, [:user_id]))
    create(index(:platform_role_grants, [:tenant_id, :expires_at]))

    execute("""
    ALTER TABLE platform_role_grants
    ADD CONSTRAINT platform_role_grants_tenant_user_fk
      FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id)
    """)

    create(
      constraint(:platform_role_grants, :platform_role_grants_role_allowed,
        check: "role IN ('platform_operator', 'support_operator', 'security_operator')"
      )
    )

    create(
      constraint(:platform_role_grants, :platform_role_grants_expiry_after_creation,
        check: "expires_at > inserted_at"
      )
    )

    # Give existing operators a bounded transition window. The legacy column is
    # then cleared and constrained to NULL so a rolled-back binary fails closed.
    execute("""
    INSERT INTO platform_role_grants
      (id, tenant_id, user_id, role, expires_at, inserted_at, updated_at)
    SELECT
      gen_random_uuid(), tenant_id, id, platform_role,
      timezone('utc', now()) + interval '8 hours',
      timezone('utc', now()), timezone('utc', now())
    FROM users
    WHERE platform_role IS NOT NULL
    """)

    execute("UPDATE users SET platform_role = NULL WHERE platform_role IS NOT NULL")

    create(constraint(:users, :users_platform_role_deprecated, check: "platform_role IS NULL"))
  end

  def down do
    # Do not restore a non-expiring privilege into the legacy column.
    drop(constraint(:users, :users_platform_role_deprecated))
    drop(table(:platform_role_grants))
  end
end
