defmodule CommsCore.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration
  def change do
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :status, :text, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:tenants, [:slug])

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :external_subject, :text, null: false
      add :display_name, :text, null: false
      add :email, :text
      add :status, :text, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:users, [:tenant_id, :external_subject])

    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :platform, :text, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :title, :text
      add :visibility, :text, null: false, default: "private"
      add :next_sequence, :bigint, null: false, default: 1
      add :archived_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
    create index(:conversations, [:tenant_id, :inserted_at])

    create table(:conversation_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text, null: false, default: "member"
      add :joined_at, :utc_datetime_usec, null: false
      add :left_at, :utc_datetime_usec
      add :last_read_sequence, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:conversation_memberships, [:conversation_id, :user_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :sender_user_id, references(:users, type: :binary_id), null: false
      add :sender_device_id, references(:devices, type: :binary_id), null: false
      add :client_message_id, :text, null: false
      add :conversation_sequence, :bigint, null: false
      add :body, :text
      add :status, :text, null: false, default: "active"
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create constraint(:messages, :message_has_content, check: "body IS NOT NULL AND length(body) > 0")
    create unique_index(:messages, [:conversation_id, :conversation_sequence])
    create unique_index(:messages, [:tenant_id, :sender_device_id, :client_message_id])

    create table(:outbox_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :text, null: false
      add :aggregate_type, :text, null: false
      add :aggregate_id, :binary_id, null: false
      add :payload, :map, null: false
      add :available_at, :utc_datetime_usec, null: false
      add :published_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create index(:outbox_events, [:published_at, :available_at])

    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :actor_user_id, references(:users, type: :binary_id)
      add :action, :text, null: false
      add :resource_type, :text, null: false
      add :resource_id, :binary_id, null: false
      add :metadata, :map, null: false, default: %{}
      add :request_id, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create index(:audit_events, [:tenant_id, :inserted_at])
  end
end
