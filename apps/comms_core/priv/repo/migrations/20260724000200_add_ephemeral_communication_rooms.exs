defmodule CommsCore.Repo.Migrations.AddEphemeralCommunicationRooms do
  use Ecto.Migration

  def up do
    alter table(:conversation_guest_links) do
      add(:purpose, :text, null: false, default: "standard")
    end

    alter table(:conversation_guest_admissions) do
      add(:join_idempotency_digest, :binary)
      add(:request_fingerprint, :binary)
      add(:idempotency_expires_at, :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE conversation_guest_links
    DROP CONSTRAINT IF EXISTS conversation_guest_links_expiry_check
    """)

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_purpose_check,
        check: "purpose IN ('standard', 'ephemeral_room')"
      )
    )

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_expiry_check,
        check:
          "expires_at > inserted_at AND " <>
            "(purpose = 'ephemeral_room' OR expires_at <= inserted_at + interval '24 hours')"
      )
    )

    create(
      constraint(
        :conversation_guest_admissions,
        :conversation_guest_admissions_join_idempotency_check,
        check:
          "(join_idempotency_digest IS NULL AND request_fingerprint IS NULL " <>
            "AND idempotency_expires_at IS NULL) OR " <>
            "(octet_length(join_idempotency_digest) = 32 AND octet_length(request_fingerprint) = 32 " <>
            "AND idempotency_expires_at > admitted_at)"
      )
    )

    create(
      unique_index(
        :conversation_guest_admissions,
        [:guest_link_id, :join_idempotency_digest],
        where: "join_idempotency_digest IS NOT NULL",
        name: :conversation_guest_admissions_link_join_idempotency_unique
      )
    )

    create table(:conversation_ephemeral_rooms, primary_key: false) do
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

      add(:creator_user_id, references(:users, type: :binary_id), null: false)
      add(:creator_session_id, references(:sessions, type: :binary_id), null: false)
      add(:owner_kind, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:idempotency_digest, :binary, null: false)
      add(:request_fingerprint, :binary, null: false)
      add(:replay_ciphertext, :binary)
      add(:replay_nonce, :binary)
      add(:replay_tag, :binary)
      add(:replay_key_id, :text)
      add(:replay_erased_at, :utc_datetime_usec)
      add(:idempotency_expires_at, :utc_datetime_usec, null: false)
      add(:generation, :bigint, null: false, default: 1)
      add(:participant_limit, :integer, null: false)
      add(:reconnect_grace_seconds, :integer, null: false)
      add(:idle_ttl_seconds, :integer, null: false)
      add(:authority_expires_at, :utc_datetime_usec, null: false)
      add(:last_presence_at, :utc_datetime_usec)
      add(:idle_since, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)
      add(:expired_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_ephemeral_rooms, [:conversation_id]))
    create(unique_index(:conversation_ephemeral_rooms, [:guest_link_id]))

    create(
      unique_index(
        :conversation_ephemeral_rooms,
        [:tenant_id, :idempotency_digest],
        name: :conversation_ephemeral_rooms_tenant_idempotency_unique
      )
    )

    create(
      unique_index(
        :conversation_ephemeral_rooms,
        [:tenant_id, :id],
        name: :conversation_ephemeral_rooms_tenant_id_id_unique
      )
    )

    create(
      unique_index(
        :conversation_ephemeral_rooms,
        [:tenant_id, :conversation_id, :id],
        name: :conversation_ephemeral_rooms_tenant_conversation_id_unique
      )
    )

    create(
      index(
        :conversation_ephemeral_rooms,
        [:status, :updated_at, :id],
        where: "status <> 'expired'",
        name: :conversation_ephemeral_rooms_reconcile_index
      )
    )

    create(
      index(
        :conversation_ephemeral_rooms,
        [:expires_at, :id],
        where: "status = 'idle'",
        name: :conversation_ephemeral_rooms_expiry_index
      )
    )

    create(
      constraint(
        :conversation_ephemeral_rooms,
        :conversation_ephemeral_rooms_owner_kind_check,
        check: "owner_kind IN ('guest', 'registered')"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_rooms,
        :conversation_ephemeral_rooms_status_check,
        check: "status IN ('active', 'idle', 'expired')"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_rooms,
        :conversation_ephemeral_rooms_digest_check,
        check:
          "octet_length(idempotency_digest) = 32 AND octet_length(request_fingerprint) = 32 AND " <>
            "((replay_ciphertext IS NULL AND replay_nonce IS NULL AND replay_tag IS NULL " <>
            "AND replay_key_id IS NULL AND replay_erased_at >= idempotency_expires_at) OR " <>
            "(octet_length(replay_ciphertext) > 0 " <>
            "AND octet_length(replay_nonce) = 12 AND octet_length(replay_tag) = 16 " <>
            "AND replay_key_id IS NOT NULL AND replay_erased_at IS NULL))"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_rooms,
        :conversation_ephemeral_rooms_idempotency_expiry_check,
        check: "idempotency_expires_at > inserted_at"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_rooms,
        :conversation_ephemeral_rooms_generation_check,
        check: "generation >= 1"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_rooms,
        :conversation_ephemeral_rooms_policy_check,
        check:
          "participant_limit BETWEEN 2 AND 25 AND reconnect_grace_seconds BETWEEN 3 AND 300 " <>
            "AND idle_ttl_seconds BETWEEN 60 AND 86400"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_rooms,
        :conversation_ephemeral_rooms_state_check,
        check:
          "(status = 'active' AND idle_since IS NULL AND expires_at IS NULL AND expired_at IS NULL) OR " <>
            "(status = 'idle' AND idle_since IS NOT NULL AND expires_at > idle_since AND expired_at IS NULL) OR " <>
            "(status = 'expired' AND idle_since IS NOT NULL AND expires_at IS NOT NULL AND expired_at IS NOT NULL)"
      )
    )

    create table(:conversation_ephemeral_presence_leases, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :ephemeral_room_id,
        references(:conversation_ephemeral_rooms, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(:session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:connection_digest, :binary, null: false)
      add(:opened_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:closed_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :conversation_ephemeral_presence_leases,
        [:ephemeral_room_id, :connection_digest],
        name: :conversation_ephemeral_presence_leases_room_connection_unique
      )
    )

    create(
      index(
        :conversation_ephemeral_presence_leases,
        [:ephemeral_room_id, :expires_at],
        where: "closed_at IS NULL",
        name: :conversation_ephemeral_presence_leases_active_index
      )
    )

    create(
      constraint(
        :conversation_ephemeral_presence_leases,
        :conversation_ephemeral_presence_leases_digest_check,
        check: "octet_length(connection_digest) = 32"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_presence_leases,
        :conversation_ephemeral_presence_leases_expiry_check,
        check: "expires_at > last_seen_at AND last_seen_at >= opened_at"
      )
    )

    execute("""
    ALTER TABLE conversation_ephemeral_rooms
      ADD CONSTRAINT conversation_ephemeral_rooms_tenant_conversation_fk
        FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id),
      ADD CONSTRAINT conversation_ephemeral_rooms_tenant_link_fk
        FOREIGN KEY (tenant_id, conversation_id, guest_link_id)
        REFERENCES conversation_guest_links (tenant_id, conversation_id, id),
      ADD CONSTRAINT conversation_ephemeral_rooms_tenant_creator_fk
        FOREIGN KEY (tenant_id, creator_user_id) REFERENCES users (tenant_id, id),
      ADD CONSTRAINT conversation_ephemeral_rooms_tenant_creator_session_fk
        FOREIGN KEY (tenant_id, creator_user_id, creator_session_id)
        REFERENCES sessions (tenant_id, user_id, id)
    """)

    execute("""
    ALTER TABLE conversation_ephemeral_presence_leases
      ADD CONSTRAINT conversation_ephemeral_presence_leases_tenant_room_fk
        FOREIGN KEY (tenant_id, conversation_id, ephemeral_room_id)
        REFERENCES conversation_ephemeral_rooms (tenant_id, conversation_id, id),
      ADD CONSTRAINT conversation_ephemeral_presence_leases_tenant_conversation_fk
        FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id),
      ADD CONSTRAINT conversation_ephemeral_presence_leases_tenant_user_fk
        FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
      ADD CONSTRAINT conversation_ephemeral_presence_leases_tenant_session_fk
        FOREIGN KEY (tenant_id, user_id, session_id) REFERENCES sessions (tenant_id, user_id, id)
    """)

    create table(:conversation_ephemeral_join_receipts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :ephemeral_room_id,
        references(:conversation_ephemeral_rooms, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :membership_id,
        references(:conversation_memberships, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:idempotency_digest, :binary, null: false)
      add(:request_fingerprint, :binary, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :conversation_ephemeral_join_receipts,
        [:ephemeral_room_id, :idempotency_digest],
        name: :conversation_ephemeral_join_receipts_room_idempotency_unique
      )
    )

    create(
      index(
        :conversation_ephemeral_join_receipts,
        [:expires_at],
        name: :conversation_ephemeral_join_receipts_expiry_index
      )
    )

    create(
      constraint(
        :conversation_ephemeral_join_receipts,
        :conversation_ephemeral_join_receipts_digest_check,
        check: "octet_length(idempotency_digest) = 32 AND octet_length(request_fingerprint) = 32"
      )
    )

    create(
      constraint(
        :conversation_ephemeral_join_receipts,
        :conversation_ephemeral_join_receipts_expiry_check,
        check: "expires_at > inserted_at"
      )
    )

    execute("""
    ALTER TABLE conversation_ephemeral_join_receipts
      ADD CONSTRAINT conversation_ephemeral_join_receipts_tenant_room_fk
        FOREIGN KEY (tenant_id, conversation_id, ephemeral_room_id)
        REFERENCES conversation_ephemeral_rooms (tenant_id, conversation_id, id),
      ADD CONSTRAINT conversation_ephemeral_join_receipts_tenant_membership_fk
        FOREIGN KEY (tenant_id, conversation_id, user_id, membership_id)
        REFERENCES conversation_memberships (tenant_id, conversation_id, user_id, id)
    """)
  end

  def down do
    drop_if_exists(table(:conversation_ephemeral_join_receipts))
    drop(table(:conversation_ephemeral_presence_leases))
    drop(table(:conversation_ephemeral_rooms))

    drop_if_exists(
      index(
        :conversation_guest_admissions,
        [:guest_link_id, :join_idempotency_digest],
        name: :conversation_guest_admissions_link_join_idempotency_unique
      )
    )

    execute("""
    ALTER TABLE conversation_guest_admissions
    DROP CONSTRAINT IF EXISTS conversation_guest_admissions_join_idempotency_check
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
      DROP COLUMN IF EXISTS idempotency_expires_at,
      DROP COLUMN IF EXISTS request_fingerprint,
      DROP COLUMN IF EXISTS join_idempotency_digest
    """)

    execute("""
    ALTER TABLE conversation_guest_links
    DROP CONSTRAINT IF EXISTS conversation_guest_links_expiry_check
    """)

    execute("""
    ALTER TABLE conversation_guest_links
    DROP CONSTRAINT IF EXISTS conversation_guest_links_purpose_check
    """)

    alter table(:conversation_guest_links) do
      remove(:purpose)
    end

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_expiry_check,
        check: "expires_at > inserted_at AND expires_at <= inserted_at + interval '24 hours'"
      )
    )
  end
end
