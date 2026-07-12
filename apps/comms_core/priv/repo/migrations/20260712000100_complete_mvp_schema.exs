defmodule CommsCore.Repo.Migrations.CompleteMvpSchema do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :password_hash, :text
      add :role, :text, null: false, default: "member"
    end

    execute("UPDATE users SET email = external_subject || '@invalid.local' WHERE email IS NULL")
    execute("CREATE UNIQUE INDEX users_tenant_email_unique ON users (tenant_id, lower(email))")

    alter table(:devices) do
      add :last_seen_at, :utc_datetime_usec
    end

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false
      add :refresh_token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:user_id, :revoked_at])
    create index(:sessions, [:expires_at])

    alter table(:conversations) do
      add :created_by_user_id, references(:users, type: :binary_id)
      add :direct_key, :text
    end

    execute("UPDATE conversations SET created_by_user_id = (SELECT user_id FROM conversation_memberships WHERE conversation_id = conversations.id ORDER BY inserted_at LIMIT 1) WHERE created_by_user_id IS NULL")
    create unique_index(:conversations, [:tenant_id, :direct_key], where: "direct_key IS NOT NULL", name: :conversations_tenant_direct_key_unique)

    drop constraint(:messages, :message_has_content)

    alter table(:messages) do
      add :reply_to_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}
      add :edited_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
    end

    create constraint(:messages, :active_message_has_content,
             check: "status <> 'active' OR (body IS NOT NULL AND length(trim(body)) > 0)"
           )

    create index(:messages, [:conversation_id, :reply_to_message_id])
    execute("CREATE INDEX messages_search_idx ON messages USING GIN (to_tsvector('simple', coalesce(body, '')))")

    create table(:message_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :editor_user_id, references(:users, type: :binary_id), null: false
      add :body, :text, null: false
      add :revision, :integer, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:message_revisions, [:message_id, :revision])

    create table(:message_reactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :emoji, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:message_reactions, [:message_id, :user_id, :emoji])

    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
      add :object_key, :text, null: false
      add :file_name, :text, null: false
      add :content_type, :text, null: false
      add :byte_size, :bigint, null: false
      add :checksum_sha256, :text
      add :status, :text, null: false, default: "pending"
      add :uploaded_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:attachments, [:object_key])
    create index(:attachments, [:tenant_id, :owner_user_id, :status])
    create index(:attachments, [:message_id])
  end

  def down do
    drop table(:attachments)
    drop table(:message_reactions)
    drop table(:message_revisions)
    execute("DROP INDEX IF EXISTS messages_search_idx")
    drop constraint(:messages, :active_message_has_content)

    alter table(:messages) do
      remove :reply_to_message_id
      remove :metadata
      remove :edited_at
      remove :deleted_at
    end

    create constraint(:messages, :message_has_content,
             check: "body IS NOT NULL AND length(body) > 0"
           )

    drop index(:conversations, [:tenant_id, :direct_key], name: :conversations_tenant_direct_key_unique)

    alter table(:conversations) do
      remove :created_by_user_id
      remove :direct_key
    end

    drop table(:sessions)

    alter table(:devices) do
      remove :last_seen_at
    end

    execute("DROP INDEX IF EXISTS users_tenant_email_unique")

    alter table(:users) do
      remove :password_hash
      remove :role
    end
  end
end
