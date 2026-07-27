defmodule CommsCore.Repo.Migrations.RepairConversationGuestAccessConstraints do
  use Ecto.Migration

  def up do
    reconcile_guest_access_schema()
  end

  def down do
    # The preceding migrations own these invariants. Retain the repaired schema
    # across a partial migration rollback so it still matches a fresh install.
    reconcile_guest_access_schema()
  end

  defp reconcile_guest_access_schema do
    execute("""
    ALTER TABLE conversation_guest_admissions
    DROP CONSTRAINT IF EXISTS conversation_guest_admissions_tenant_link_fk
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    DROP CONSTRAINT IF EXISTS conversation_guest_admissions_tenant_membership_fk
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    DROP CONSTRAINT IF EXISTS conversation_guest_admissions_tenant_session_fk
    """)

    execute("""
    ALTER TABLE conversation_guest_links
    DROP CONSTRAINT IF EXISTS conversation_guest_links_digest_check
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    DROP CONSTRAINT IF EXISTS conversation_guest_admissions_expiry_check
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    DROP CONSTRAINT IF EXISTS conversation_guest_admissions_history_sequence_check
    """)

    execute("""
    ALTER TABLE conversation_guest_links
    DROP CONSTRAINT IF EXISTS conversation_guest_links_conversion_verification_digest_check
    """)

    execute("""
    DROP INDEX IF EXISTS conversation_guest_links_tenant_conversation_id_unique
    """)

    execute("""
    DROP INDEX IF EXISTS conversation_guest_admissions_membership_id_index
    """)

    execute("""
    DROP INDEX IF EXISTS conversation_memberships_tenant_conversation_user_id_id_unique
    """)

    execute("""
    UPDATE conversation_guest_links
    SET conversion_email = NULL
    WHERE conversion_email IS NOT NULL
      AND conversion_verification_digest IS NULL
    """)

    execute("""
    ALTER TABLE conversation_guest_links
    ADD CONSTRAINT conversation_guest_links_digest_check
    CHECK (octet_length(token_digest) = 32)
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    ADD CONSTRAINT conversation_guest_admissions_expiry_check
    CHECK (expires_at > admitted_at)
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    ADD CONSTRAINT conversation_guest_admissions_history_sequence_check
    CHECK (history_from_sequence >= 1)
    """)

    execute("""
    ALTER TABLE conversation_guest_links
    ADD CONSTRAINT conversation_guest_links_conversion_verification_digest_check
    CHECK (
      (conversion_email IS NULL AND conversion_verification_digest IS NULL)
      OR (
        conversion_email IS NOT NULL
        AND conversion_verification_digest IS NOT NULL
        AND octet_length(conversion_verification_digest) = 32
      )
    )
    """)

    execute("""
    CREATE UNIQUE INDEX conversation_guest_links_tenant_conversation_id_unique
    ON conversation_guest_links (tenant_id, conversation_id, id)
    """)

    execute("""
    CREATE UNIQUE INDEX conversation_guest_admissions_membership_id_index
    ON conversation_guest_admissions (membership_id)
    """)

    execute("""
    CREATE UNIQUE INDEX conversation_memberships_tenant_conversation_user_id_id_unique
    ON conversation_memberships (tenant_id, conversation_id, user_id, id)
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    ADD CONSTRAINT conversation_guest_admissions_tenant_link_fk
    FOREIGN KEY (tenant_id, conversation_id, guest_link_id)
    REFERENCES conversation_guest_links (tenant_id, conversation_id, id)
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    ADD CONSTRAINT conversation_guest_admissions_tenant_membership_fk
    FOREIGN KEY (tenant_id, conversation_id, guest_user_id, membership_id)
    REFERENCES conversation_memberships (tenant_id, conversation_id, user_id, id)
    """)

    execute("""
    ALTER TABLE conversation_guest_admissions
    ADD CONSTRAINT conversation_guest_admissions_tenant_session_fk
    FOREIGN KEY (tenant_id, guest_user_id, session_id)
    REFERENCES sessions (tenant_id, user_id, id)
    """)
  end
end
