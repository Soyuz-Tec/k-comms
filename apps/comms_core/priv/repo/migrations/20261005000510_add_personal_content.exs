defmodule CommsCore.Repo.Migrations.AddPersonalContent do
  use Ecto.Migration

  def up do
    create table(:message_saved_items, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:message_saved_items, [:tenant_id, :user_id, :message_id]))

    create table(:message_drafts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(:conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:thread_key, :text, null: false, default: "main")
      add(:body, :text, null: false, default: "")
      add(:version, :bigint, null: false, default: 1)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:message_drafts, [:tenant_id, :user_id, :conversation_id, :thread_key]))

    create(
      constraint(:message_drafts, :message_draft_bounded_body,
        check: "length(body) <= 65535 AND version > 0"
      )
    )

    alter table(:messages) do
      add(:attachment_count, :integer, null: false, default: 0)
    end

    execute(
      "UPDATE messages SET attachment_count = (SELECT count(*) FROM attachments WHERE attachments.message_id = messages.id)"
    )

    drop(constraint(:messages, :active_message_has_content))

    create(
      constraint(:messages, :active_message_has_content,
        check:
          "status <> 'active' OR (body IS NOT NULL AND length(trim(body)) > 0) OR attachment_count > 0"
      )
    )

    create(
      constraint(:messages, :message_attachment_count_bounded,
        check: "attachment_count >= 0 AND attachment_count <= 20"
      )
    )

    execute(
      "ALTER TABLE message_saved_items ADD CONSTRAINT message_saved_items_tenant_message_fk FOREIGN KEY (tenant_id, message_id) REFERENCES messages (tenant_id, id) ON DELETE CASCADE"
    )

    execute(
      "ALTER TABLE message_saved_items ADD CONSTRAINT message_saved_items_tenant_user_fk FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id) ON DELETE CASCADE"
    )

    execute(
      "ALTER TABLE message_drafts ADD CONSTRAINT message_drafts_tenant_user_fk FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id) ON DELETE CASCADE"
    )

    execute(
      "ALTER TABLE message_drafts ADD CONSTRAINT message_drafts_tenant_conversation_fk FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE CASCADE"
    )
  end

  def down do
    execute(
      "UPDATE messages SET body = '[Attachment]' WHERE status = 'active' AND (body IS NULL OR length(trim(body)) = 0) AND attachment_count > 0"
    )

    drop(constraint(:messages, :message_attachment_count_bounded))
    drop(constraint(:messages, :active_message_has_content))

    create(
      constraint(:messages, :active_message_has_content,
        check: "status <> 'active' OR (body IS NOT NULL AND length(trim(body)) > 0)"
      )
    )

    alter(table(:messages), do: remove(:attachment_count))
    drop(table(:message_drafts))
    drop(table(:message_saved_items))
  end
end
