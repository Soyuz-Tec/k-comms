defmodule CommsCore.Repo.Migrations.AddMatrixClientIdentity do
  use Ecto.Migration

  def up do
    create table(:matrix_identities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:issuer, :text, null: false)
      add(:matrix_user_id, :text, null: false)
      add(:auth_secret, :map)
      add(:key_cleanup_state, :text, null: false, default: "unconfirmed")
      add(:erasure_requested_at, :utc_datetime_usec)
      add(:state, :text, null: false, default: "pending")
      add(:claim_id, :uuid)
      add(:claim_expires_at, :utc_datetime_usec)
      add(:generation, :bigint, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:matrix_identities, [:tenant_id, :user_id]))
    create(unique_index(:matrix_identities, [:tenant_id, :id]))
    create(unique_index(:matrix_identities, [:tenant_id, :user_id, :id]))
    create(unique_index(:matrix_identities, [:issuer, :matrix_user_id]))

    create(
      constraint(:matrix_identities, :matrix_identity_state,
        check:
          "state IN ('pending','ready','cleanup_pending','erased') AND generation > 0 AND key_cleanup_state = 'unconfirmed' AND state <> 'erased'"
      )
    )

    create table(:matrix_client_sessions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:device_id, references(:devices, type: :uuid, on_delete: :restrict), null: false)
      add(:session_id, references(:sessions, type: :uuid, on_delete: :restrict), null: false)

      add(:matrix_identity_id, references(:matrix_identities, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:matrix_device_id, :text, null: false)
      add(:credential_secret, :map)
      add(:state, :text, null: false, default: "pending")
      add(:claim_id, :uuid)
      add(:claim_expires_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)
      add(:generation, :bigint, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:matrix_client_sessions, [:tenant_id, :session_id]))
    create(unique_index(:matrix_client_sessions, [:matrix_identity_id, :matrix_device_id]))
    create(index(:matrix_client_sessions, [:state, :expires_at]))

    create(
      constraint(:matrix_client_sessions, :matrix_client_session_state,
        check: "state IN ('pending','ready','cleanup_pending','revoked') AND generation > 0"
      )
    )

    create(
      unique_index(:sessions, [:tenant_id, :user_id, :device_id, :id],
        name: :sessions_matrix_exact_tuple
      )
    )

    execute(
      "ALTER TABLE matrix_identities ADD CONSTRAINT matrix_identity_current_user_fk FOREIGN KEY (tenant_id,user_id) REFERENCES users(tenant_id,id)",
      "SELECT 1"
    )

    execute(
      "ALTER TABLE matrix_client_sessions ADD CONSTRAINT matrix_client_current_user_fk FOREIGN KEY (tenant_id,user_id) REFERENCES users(tenant_id,id), ADD CONSTRAINT matrix_client_current_device_fk FOREIGN KEY (tenant_id,user_id,device_id) REFERENCES devices(tenant_id,user_id,id), ADD CONSTRAINT matrix_client_current_session_fk FOREIGN KEY (tenant_id,user_id,device_id,session_id) REFERENCES sessions(tenant_id,user_id,device_id,id), ADD CONSTRAINT matrix_client_user_identity_fk FOREIGN KEY (tenant_id,user_id,matrix_identity_id) REFERENCES matrix_identities(tenant_id,user_id,id)",
      "SELECT 1"
    )

    execute(
      "ALTER TABLE matrix_client_sessions ADD CONSTRAINT matrix_client_identity_tenant_fk FOREIGN KEY (tenant_id,matrix_identity_id) REFERENCES matrix_identities(tenant_id,id)",
      "SELECT 1"
    )
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM matrix_identities) OR EXISTS (SELECT 1 FROM matrix_client_sessions) THEN RAISE EXCEPTION 'refusing retained Matrix identities, credentials and revocation proof rollback'; END IF; END $$"
    )

    drop(table(:matrix_client_sessions))
    drop(table(:matrix_identities))

    drop(
      index(:sessions, [:tenant_id, :user_id, :device_id, :id],
        name: :sessions_matrix_exact_tuple
      )
    )
  end
end
