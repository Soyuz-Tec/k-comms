defmodule CommsCore.Repo.Migrations.AddServiceAccounts do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:account_type, :text, null: false, default: "human")
    end

    create(
      constraint(:users, :users_account_type_allowed,
        check: "account_type IN ('human', 'service')"
      )
    )

    create(index(:users, [:tenant_id, :account_type, :status]))

    create(
      unique_index(:devices, [:tenant_id, :user_id, :id], name: :devices_tenant_user_id_id_unique)
    )

    create table(:service_accounts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false)
      add(:created_by_user_id, references(:users, type: :binary_id), null: false)
      add(:name, :text, null: false)
      add(:credential_prefix, :text, null: false)
      add(:secret_hash, :binary, null: false)
      add(:secret_hint, :text, null: false)
      add(:scopes, {:array, :text}, null: false)
      add(:status, :text, null: false, default: "active")
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:last_used_at, :utc_datetime_usec)
      add(:last_rotated_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:credential_generation, :integer, null: false, default: 1)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:service_accounts, [:tenant_id, :id],
        name: :service_accounts_tenant_id_id_unique
      )
    )

    create(unique_index(:service_accounts, [:user_id]))
    create(unique_index(:service_accounts, [:device_id]))
    create(index(:service_accounts, [:tenant_id, :status, :expires_at]))

    execute("""
    ALTER TABLE service_accounts
    ADD CONSTRAINT service_accounts_tenant_user_fk
      FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT service_accounts_tenant_device_user_fk
      FOREIGN KEY (tenant_id, user_id, device_id) REFERENCES devices (tenant_id, user_id, id),
    ADD CONSTRAINT service_accounts_tenant_creator_fk
      FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES users (tenant_id, id)
    """)

    create(
      constraint(:service_accounts, :service_accounts_status_allowed,
        check: "status IN ('active', 'revoked', 'expired')"
      )
    )

    create(
      constraint(:service_accounts, :service_accounts_secret_hash_shape,
        check: "octet_length(secret_hash) = 32"
      )
    )

    create(
      constraint(:service_accounts, :service_accounts_credential_prefix_shape,
        check: "credential_prefix = 'kcsa_' || id::text"
      )
    )

    create(
      constraint(:service_accounts, :service_accounts_secret_hint_shape,
        check: "secret_hint ~ '^[A-Za-z0-9_-]{4}$'"
      )
    )

    create(
      constraint(:service_accounts, :service_accounts_scopes_allowed,
        check:
          "cardinality(scopes) > 0 AND scopes <@ ARRAY['conversations:read', 'messages:read', 'messages:write', 'search:read']::text[]"
      )
    )

    create(
      constraint(:service_accounts, :service_accounts_expiry_after_creation,
        check: "expires_at > inserted_at"
      )
    )

    create(
      constraint(:service_accounts, :service_accounts_revocation_consistent,
        check:
          "(status = 'revoked' AND revoked_at IS NOT NULL) OR (status IN ('active', 'expired') AND revoked_at IS NULL)"
      )
    )

    create(
      constraint(:service_accounts, :service_accounts_versions_positive,
        check: "credential_generation > 0 AND lock_version > 0"
      )
    )
  end

  def down do
    drop(table(:service_accounts))

    drop_if_exists(
      index(:devices, [:tenant_id, :user_id, :id], name: :devices_tenant_user_id_id_unique)
    )

    drop_if_exists(index(:users, [:tenant_id, :account_type, :status]))
    drop(constraint(:users, :users_account_type_allowed))

    alter table(:users) do
      remove(:account_type)
    end
  end
end
