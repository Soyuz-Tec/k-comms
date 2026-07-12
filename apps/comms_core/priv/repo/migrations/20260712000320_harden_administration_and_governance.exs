defmodule CommsCore.Repo.Migrations.HardenAdministrationAndGovernance do
  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :step_up_at, :utc_datetime_usec
    end

    alter table(:deletion_requests) do
      add :execution_started_at, :utc_datetime_usec
      add :execution_attempts, :integer, null: false, default: 0
      add :execution_error, :text
    end

    create table(:socket_tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:socket_tickets, [:token_hash])
    create index(:socket_tickets, [:expires_at], where: "consumed_at IS NULL")
    create unique_index(:sessions, [:tenant_id, :id], name: :sessions_tenant_id_id_unique)

    execute("""
    ALTER TABLE socket_tickets
    ADD CONSTRAINT socket_tickets_tenant_user_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT socket_tickets_tenant_device_fk
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    ADD CONSTRAINT socket_tickets_tenant_session_fk
    FOREIGN KEY (tenant_id, session_id) REFERENCES sessions (tenant_id, id)
    """)

    create index(:audit_events, [:tenant_id, :inserted_at, :id],
             name: :audit_events_tenant_cursor_index
           )

    create unique_index(:retention_policies, [:tenant_id],
             where: "scope_type = 'tenant' AND status = 'active'",
             name: :retention_policies_one_active_tenant_policy
           )

    create unique_index(:retention_policies, [:tenant_id, :conversation_id],
             where: "scope_type = 'conversation' AND status = 'active'",
             name: :retention_policies_one_active_conversation_policy
           )
  end

  def down do
    drop table(:socket_tickets)
    drop_if_exists index(:sessions, [:tenant_id, :id], name: :sessions_tenant_id_id_unique)

    drop_if_exists index(:retention_policies, [:tenant_id, :conversation_id],
                     name: :retention_policies_one_active_conversation_policy
                   )

    drop_if_exists index(:retention_policies, [:tenant_id],
                     name: :retention_policies_one_active_tenant_policy
                   )

    drop_if_exists index(:audit_events, [:tenant_id, :inserted_at, :id],
                     name: :audit_events_tenant_cursor_index
                   )

    alter table(:deletion_requests) do
      remove :execution_error
      remove :execution_attempts
      remove :execution_started_at
    end

    alter table(:sessions) do
      remove :step_up_at
    end

  end
end
