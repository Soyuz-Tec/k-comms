defmodule CommsCore.Repo.Migrations.AddAdministrationAndGovernance do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :lock_version, :integer, null: false, default: 1
    end

    alter table(:conversations) do
      add :lock_version, :integer, null: false, default: 1
    end

    alter table(:conversation_memberships) do
      add :lock_version, :integer, null: false, default: 1
    end

    create table(:tenant_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :allow_public_channels, :boolean, null: false, default: true
      add :message_edit_window_seconds, :integer, null: false, default: 86_400
      add :max_attachment_bytes, :bigint, null: false, default: 26_214_400
      add :default_retention_days, :integer
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenant_settings, [:tenant_id])

    create constraint(:tenant_settings, :tenant_settings_edit_window_non_negative,
             check: "message_edit_window_seconds >= 0"
           )

    create constraint(:tenant_settings, :tenant_settings_attachment_size_positive,
             check: "max_attachment_bytes > 0"
           )

    create constraint(:tenant_settings, :tenant_settings_retention_positive,
             check: "default_retention_days IS NULL OR default_retention_days > 0"
           )

    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :text, null: false
      add :role, :text, null: false, default: "member"
      add :token_hash, :binary, null: false
      add :status, :text, null: false, default: "pending"
      add :invited_by_user_id, references(:users, type: :binary_id), null: false
      add :accepted_user_id, references(:users, type: :binary_id)
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :idempotency_key, :text
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create index(:invitations, [:tenant_id, :status, :inserted_at])
    create unique_index(:invitations, [:tenant_id, :idempotency_key], where: "idempotency_key IS NOT NULL")

    create unique_index(:invitations, [:tenant_id, "lower(email)"],
             where: "status = 'pending'",
             name: :invitations_tenant_pending_email_unique
           )

    create table(:moderation_cases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :reporter_user_id, references(:users, type: :binary_id), null: false
      add :subject_user_id, references(:users, type: :binary_id)
      add :conversation_id, references(:conversations, type: :binary_id)
      add :message_id, references(:messages, type: :binary_id)
      add :assigned_to_user_id, references(:users, type: :binary_id)
      add :category, :text, null: false
      add :summary, :text, null: false
      add :details, :text
      add :priority, :text, null: false, default: "normal"
      add :status, :text, null: false, default: "open"
      add :resolved_at, :utc_datetime_usec
      add :idempotency_key, :text
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:moderation_cases, [:tenant_id, :id])
    create index(:moderation_cases, [:tenant_id, :status, :inserted_at])
    create index(:moderation_cases, [:tenant_id, :assigned_to_user_id, :status])
    create unique_index(:moderation_cases, [:tenant_id, :reporter_user_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :moderation_cases_idem_unique
           )

    create constraint(:moderation_cases, :moderation_case_target_required,
             check:
               "subject_user_id IS NOT NULL OR conversation_id IS NOT NULL OR message_id IS NOT NULL"
           )

    create table(:moderation_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :moderation_case_id, references(:moderation_cases, type: :binary_id, on_delete: :delete_all), null: false
      add :actor_user_id, references(:users, type: :binary_id), null: false
      add :action_type, :text, null: false
      add :note, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:moderation_actions, [:tenant_id, :moderation_case_id, :inserted_at],
             name: :moderation_actions_case_time_index
           )

    create table(:retention_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all)
      add :name, :text, null: false
      add :scope_type, :text, null: false, default: "tenant"
      add :retention_days, :integer, null: false
      add :delete_attachments, :boolean, null: false, default: true
      add :status, :text, null: false, default: "active"
      add :idempotency_key, :text
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:retention_policies, [:tenant_id, :id])
    create index(:retention_policies, [:tenant_id, :scope_type, :status])
    create unique_index(:retention_policies, [:tenant_id, :idempotency_key], where: "idempotency_key IS NOT NULL")

    create constraint(:retention_policies, :retention_policy_scope_target,
             check:
               "(scope_type = 'tenant' AND conversation_id IS NULL) OR " <>
                 "(scope_type = 'conversation' AND conversation_id IS NOT NULL)"
           )

    create constraint(:retention_policies, :retention_policy_days_positive,
             check: "retention_days > 0"
           )

    create table(:legal_holds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_user_id, references(:users, type: :binary_id), null: false
      add :subject_user_id, references(:users, type: :binary_id)
      add :conversation_id, references(:conversations, type: :binary_id)
      add :name, :text, null: false
      add :reason, :text, null: false
      add :scope_type, :text, null: false
      add :status, :text, null: false, default: "active"
      add :starts_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
      add :idempotency_key, :text
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:legal_holds, [:tenant_id, :id])
    create index(:legal_holds, [:tenant_id, :status, :inserted_at])
    create unique_index(:legal_holds, [:tenant_id, :idempotency_key], where: "idempotency_key IS NOT NULL")

    create constraint(:legal_holds, :legal_hold_scope_target,
             check:
               "(scope_type = 'tenant' AND subject_user_id IS NULL AND conversation_id IS NULL) OR " <>
                 "(scope_type = 'user' AND subject_user_id IS NOT NULL AND conversation_id IS NULL) OR " <>
                 "(scope_type = 'conversation' AND subject_user_id IS NULL AND conversation_id IS NOT NULL)"
           )

    create table(:deletion_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :requested_by_user_id, references(:users, type: :binary_id), null: false
      add :subject_user_id, references(:users, type: :binary_id)
      add :conversation_id, references(:conversations, type: :binary_id)
      add :message_id, references(:messages, type: :binary_id)
      add :target_type, :text, null: false
      add :reason, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :scheduled_for, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :evidence, :map, null: false, default: %{}
      add :idempotency_key, :text
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:deletion_requests, [:tenant_id, :id])
    create index(:deletion_requests, [:tenant_id, :status, :inserted_at])
    create unique_index(:deletion_requests, [:tenant_id, :idempotency_key], where: "idempotency_key IS NOT NULL")

    create constraint(:deletion_requests, :deletion_request_target,
             check:
               "(target_type = 'user' AND subject_user_id IS NOT NULL AND conversation_id IS NULL AND message_id IS NULL) OR " <>
                 "(target_type = 'conversation' AND subject_user_id IS NULL AND conversation_id IS NOT NULL AND message_id IS NULL) OR " <>
                 "(target_type = 'message' AND subject_user_id IS NULL AND conversation_id IS NULL AND message_id IS NOT NULL)"
           )

    add_tenant_foreign_keys()
  end

  def down do
    drop table(:deletion_requests)
    drop table(:legal_holds)
    drop table(:retention_policies)
    drop table(:moderation_actions)
    drop table(:moderation_cases)
    drop table(:invitations)
    drop table(:tenant_settings)

    alter table(:conversation_memberships), do: remove(:lock_version)
    alter table(:conversations), do: remove(:lock_version)
    alter table(:users), do: remove(:lock_version)
  end

  defp add_tenant_foreign_keys do
    constraints = [
      {:invitations, :invitations_tenant_inviter_fk, [:tenant_id, :invited_by_user_id], :users},
      {:invitations, :invitations_tenant_accepted_user_fk, [:tenant_id, :accepted_user_id], :users},
      {:moderation_cases, :moderation_cases_tenant_reporter_fk, [:tenant_id, :reporter_user_id], :users},
      {:moderation_cases, :moderation_cases_tenant_subject_fk, [:tenant_id, :subject_user_id], :users},
      {:moderation_cases, :moderation_cases_tenant_assignee_fk, [:tenant_id, :assigned_to_user_id], :users},
      {:moderation_cases, :moderation_cases_tenant_conversation_fk, [:tenant_id, :conversation_id], :conversations},
      {:moderation_cases, :moderation_cases_tenant_message_fk, [:tenant_id, :message_id], :messages},
      {:moderation_actions, :moderation_actions_tenant_case_fk, [:tenant_id, :moderation_case_id], :moderation_cases},
      {:moderation_actions, :moderation_actions_tenant_actor_fk, [:tenant_id, :actor_user_id], :users},
      {:retention_policies, :retention_policies_tenant_conversation_fk, [:tenant_id, :conversation_id], :conversations},
      {:legal_holds, :legal_holds_tenant_creator_fk, [:tenant_id, :created_by_user_id], :users},
      {:legal_holds, :legal_holds_tenant_subject_fk, [:tenant_id, :subject_user_id], :users},
      {:legal_holds, :legal_holds_tenant_conversation_fk, [:tenant_id, :conversation_id], :conversations},
      {:deletion_requests, :deletion_requests_tenant_requester_fk, [:tenant_id, :requested_by_user_id], :users},
      {:deletion_requests, :deletion_requests_tenant_subject_fk, [:tenant_id, :subject_user_id], :users},
      {:deletion_requests, :deletion_requests_tenant_conversation_fk, [:tenant_id, :conversation_id], :conversations},
      {:deletion_requests, :deletion_requests_tenant_message_fk, [:tenant_id, :message_id], :messages}
    ]

    for {table, name, columns, target} <- constraints do
      execute(
        "ALTER TABLE #{table} ADD CONSTRAINT #{name} FOREIGN KEY (#{Enum.join(columns, ", ")}) " <>
          "REFERENCES #{target} (tenant_id, id)"
      )
    end
  end
end
