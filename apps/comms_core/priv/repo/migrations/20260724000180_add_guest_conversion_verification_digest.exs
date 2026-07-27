defmodule CommsCore.Repo.Migrations.AddGuestConversionVerificationDigest do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE conversation_guest_links
    ADD COLUMN IF NOT EXISTS conversion_email text
    """)

    alter table(:conversation_guest_links) do
      add(:conversion_verification_digest, :binary)
    end

    execute("""
    UPDATE conversation_guest_links
    SET conversion_email = NULL
    WHERE conversion_email IS NOT NULL
    """)

    create(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_conversion_verification_digest_check,
        check:
          "(conversion_email IS NULL AND conversion_verification_digest IS NULL) OR " <>
            "(conversion_email IS NOT NULL AND conversion_verification_digest IS NOT NULL AND " <>
            "octet_length(conversion_verification_digest) = 32)"
      )
    )
  end

  def down do
    drop(
      constraint(
        :conversation_guest_links,
        :conversation_guest_links_conversion_verification_digest_check
      )
    )

    alter table(:conversation_guest_links) do
      remove(:conversion_verification_digest)
    end
  end
end
