defmodule CommsCore.Repo.Migrations.AddConversationGuestAccess do
  use Ecto.Migration

  def up do
    create table(:conversation_guest_links, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:created_by_user_id, references(:users, type: :binary_id), null: false)
      add(:token_digest, :binary, null: false)
      add(:conversion_email, :text)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:max_uses, :integer, null: false)
      add(:use_count, :integer, null: false, default: 0)
      add(:revoked_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_max_uses_check,
        check: "max_uses BETWEEN 1 AND 25"
      )
    )

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_use_count_check,
        check: "use_count >= 0 AND use_count <= max_uses"
      )
    )

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_digest_check,
        check: "octet_length(token_digest) = 32"
      )
    )

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_expiry_check,
        check: "expires_at > inserted_at AND expires_at <= inserted_at + interval '24 hours'"
      )
    )

    create(unique_index(:conversation_guest_links, [:token_digest]))

    create(
      unique_index(:conversation_guest_links, [:tenant_id, :id],
        name: :conversation_guest_links_tenant_id_id_unique
      )
    )

    create(
      unique_index(:conversation_guest_links, [:tenant_id, :conversation_id, :id],
        name: :conversation_guest_links_tenant_conversation_id_unique
      )
    )

    create(
      index(:conversation_guest_links, [:tenant_id, :conversation_id, :inserted_at],
        name: :conversation_guest_links_conversation_index
      )
    )

    create(
      index(:conversation_guest_links, [:expires_at],
        where: "revoked_at IS NULL AND use_count < max_uses",
        name: :conversation_guest_links_active_expiry_index
      )
    )

    create(
      unique_index(:conversation_memberships, [:tenant_id, :id],
        name: :conversation_memberships_tenant_id_id_unique
      )
    )

    create(
      unique_index(
        :conversation_memberships,
        [:tenant_id, :conversation_id, :user_id, :id],
        name: :conversation_memberships_tenant_conversation_user_id_id_unique
      )
    )

    create table(:conversation_guest_admissions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :guest_link_id,
        references(:conversation_guest_links, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:guest_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :membership_id,
        references(:conversation_memberships, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:admitted_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:converted_at, :utc_datetime_usec)
      add(:history_from_sequence, :bigint, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_guest_admissions, [:session_id]))
    create(unique_index(:conversation_guest_admissions, [:membership_id]))

    create(
      constraint(
        :conversation_guest_admissions,
        :conversation_guest_admissions_expiry_check,
        check: "expires_at > admitted_at"
      )
    )

    create(
      constraint(
        :conversation_guest_admissions,
        :conversation_guest_admissions_history_sequence_check,
        check: "history_from_sequence >= 1"
      )
    )

    create(
      index(
        :conversation_guest_admissions,
        [:tenant_id, :conversation_id, :guest_user_id],
        name: :conversation_guest_admissions_access_index
      )
    )

    create(
      index(:conversation_guest_admissions, [:guest_link_id, :revoked_at],
        name: :conversation_guest_admissions_link_index
      )
    )

    execute("""
    ALTER TABLE conversation_guest_links
      ADD CONSTRAINT conversation_guest_links_tenant_conversation_fk
        FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id),
      ADD CONSTRAINT conversation_guest_links_tenant_creator_fk
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES users (tenant_id, id)
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
      ADD CONSTRAINT conversation_guest_admissions_tenant_conversation_fk
        FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id),
      ADD CONSTRAINT conversation_guest_admissions_tenant_link_fk
        FOREIGN KEY (tenant_id, conversation_id, guest_link_id)
        REFERENCES conversation_guest_links (tenant_id, conversation_id, id),
      ADD CONSTRAINT conversation_guest_admissions_tenant_user_fk
        FOREIGN KEY (tenant_id, guest_user_id) REFERENCES users (tenant_id, id),
      ADD CONSTRAINT conversation_guest_admissions_tenant_membership_fk
        FOREIGN KEY (tenant_id, conversation_id, guest_user_id, membership_id)
        REFERENCES conversation_memberships (tenant_id, conversation_id, user_id, id),
      ADD CONSTRAINT conversation_guest_admissions_tenant_session_fk
        FOREIGN KEY (tenant_id, guest_user_id, session_id)
        REFERENCES sessions (tenant_id, user_id, id)
    """)
  end

  def down do
    drop(table(:conversation_guest_admissions))

    drop_if_exists(
      index(
        :conversation_memberships,
        [:tenant_id, :conversation_id, :user_id, :id],
        name: :conversation_memberships_tenant_conversation_user_id_id_unique
      )
    )

    drop_if_exists(
      index(:conversation_memberships, [:tenant_id, :id],
        name: :conversation_memberships_tenant_id_id_unique
      )
    )

    drop(table(:conversation_guest_links))
  end
end
