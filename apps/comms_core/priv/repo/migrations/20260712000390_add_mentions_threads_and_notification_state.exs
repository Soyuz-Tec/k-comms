defmodule CommsCore.Repo.Migrations.AddMentionsThreadsAndNotificationState do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add(:thread_root_message_id, :binary_id)
    end

    create(
      unique_index(:messages, [:tenant_id, :conversation_id, :id],
        name: :messages_tenant_conversation_id_id_unique
      )
    )

    execute("""
    WITH RECURSIVE ancestry AS (
      SELECT child.id AS origin_id,
             child.tenant_id,
             child.conversation_id,
             parent.id AS ancestor_id,
             parent.reply_to_message_id AS next_parent_id,
             1 AS depth
      FROM messages child
      JOIN messages parent
        ON parent.id = child.reply_to_message_id
       AND parent.tenant_id = child.tenant_id
       AND parent.conversation_id = child.conversation_id
      WHERE child.reply_to_message_id IS NOT NULL

      UNION ALL

      SELECT ancestry.origin_id,
             ancestry.tenant_id,
             ancestry.conversation_id,
             parent.id AS ancestor_id,
             parent.reply_to_message_id AS next_parent_id,
             ancestry.depth + 1
      FROM ancestry
      JOIN messages parent
        ON parent.id = ancestry.next_parent_id
       AND parent.tenant_id = ancestry.tenant_id
       AND parent.conversation_id = ancestry.conversation_id
      WHERE ancestry.next_parent_id IS NOT NULL
        AND ancestry.depth < 100
    ), roots AS (
      SELECT DISTINCT ON (origin_id) origin_id, ancestor_id AS root_id
      FROM ancestry
      WHERE next_parent_id IS NULL
      ORDER BY origin_id, depth DESC
    )
    UPDATE messages
    SET thread_root_message_id = roots.root_id
    FROM roots
    WHERE messages.id = roots.origin_id
    """)

    create(
      constraint(:messages, :messages_thread_root_not_self,
        check: "thread_root_message_id IS NULL OR thread_root_message_id <> id"
      )
    )

    execute("""
    ALTER TABLE messages
    ADD CONSTRAINT messages_tenant_conversation_thread_root_fk
    FOREIGN KEY (tenant_id, conversation_id, thread_root_message_id)
    REFERENCES messages (tenant_id, conversation_id, id)
    ON DELETE SET NULL (thread_root_message_id)
    """)

    create(
      index(:messages, [:conversation_id, :thread_root_message_id, :conversation_sequence],
        name: :messages_thread_sequence_index,
        where: "thread_root_message_id IS NOT NULL"
      )
    )

    create table(:message_mentions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:message_mentions, [:message_id, :user_id]))
    create(index(:message_mentions, [:tenant_id, :user_id, :inserted_at]))

    execute("""
    ALTER TABLE message_mentions
    ADD CONSTRAINT message_mentions_tenant_message_fk
    FOREIGN KEY (tenant_id, message_id) REFERENCES messages (tenant_id, id),
    ADD CONSTRAINT message_mentions_tenant_user_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id)
    """)

    alter table(:notification_intents) do
      add(:read_at, :utc_datetime_usec)
      add(:dismissed_at, :utc_datetime_usec)
    end

    create(
      constraint(:notification_intents, :notification_intents_user_state_in_app_only,
        check: "(read_at IS NULL AND dismissed_at IS NULL) OR channel = 'in_app'"
      )
    )

    create(
      constraint(:notification_intents, :notification_intents_dismissed_is_read,
        check: "dismissed_at IS NULL OR read_at IS NOT NULL"
      )
    )

    create(
      index(:notification_intents, [:tenant_id, :user_id, :inserted_at],
        name: :notification_intents_unread_in_app_index,
        where: "channel = 'in_app' AND read_at IS NULL AND dismissed_at IS NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:notification_intents, [:tenant_id, :user_id, :inserted_at],
        name: :notification_intents_unread_in_app_index
      )
    )

    drop(constraint(:notification_intents, :notification_intents_dismissed_is_read))
    drop(constraint(:notification_intents, :notification_intents_user_state_in_app_only))

    alter table(:notification_intents) do
      remove(:dismissed_at)
      remove(:read_at)
    end

    drop(table(:message_mentions))

    drop_if_exists(
      index(:messages, [:conversation_id, :thread_root_message_id, :conversation_sequence],
        name: :messages_thread_sequence_index
      )
    )

    drop(constraint(:messages, :messages_tenant_conversation_thread_root_fk))
    drop(constraint(:messages, :messages_thread_root_not_self))

    drop_if_exists(
      index(:messages, [:tenant_id, :conversation_id, :id],
        name: :messages_tenant_conversation_id_id_unique
      )
    )

    alter table(:messages) do
      remove(:thread_root_message_id)
    end
  end
end
