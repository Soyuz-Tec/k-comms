defmodule CommsCore.Repo.Migrations.AddPasswordRecoveryRequests do
  use Ecto.Migration

  def up do
    create table(:password_recovery_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :invalidated_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:password_recovery_requests, [:token_hash])

    create index(:password_recovery_requests, [:user_id, :expires_at],
             where: "consumed_at IS NULL AND invalidated_at IS NULL",
             name: :password_recovery_requests_outstanding_index
           )

    execute("""
    ALTER TABLE password_recovery_requests
    ADD CONSTRAINT password_recovery_requests_tenant_user_id_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id)
    """)
  end

  def down do
    drop table(:password_recovery_requests)
  end
end
