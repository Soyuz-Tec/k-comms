defmodule CommsCore.Repo.Migrations.HardenIntegrationsAndAttachmentIdentity do
  use Ecto.Migration

  def up do
    alter table(:attachments) do
      add(:object_version_id, :text)
      add(:object_etag, :text)
      add(:verified_checksum_sha256, :text)
      add(:scan_generation, :bigint, null: false, default: 0)
      add(:scan_claim_token, :uuid)
      add(:scan_claimed_at, :utc_datetime_usec)
    end

    alter table(:notification_intents) do
      add(:claim_generation, :bigint, null: false, default: 0)
      add(:claim_token, :uuid)
    end

    alter table(:webhook_deliveries) do
      add(:claim_generation, :bigint, null: false, default: 0)
      add(:claim_token, :uuid)
    end

    alter table(:webhook_secret_versions) do
      add(:key_id, :text, null: false, default: "legacy")
    end

    execute("""
    UPDATE attachments
    SET status = 'quarantined',
        scan_status = 'pending',
        scan_verdict = 'object_identity_unverified',
        scan_error_code = 'object_identity_unverified',
        scanned_at = NULL,
        quarantined_at = COALESCE(quarantined_at, NOW())
    WHERE status = 'ready'
      AND (object_version_id IS NULL OR object_etag IS NULL OR verified_checksum_sha256 IS NULL)
    """)

    execute("""
    UPDATE attachments
    SET status = 'scan_failed',
        scan_status = 'failed',
        scan_error_code = 'scan_claim_migrated',
        quarantined_at = COALESCE(quarantined_at, NOW())
    WHERE scan_status = 'scanning'
    """)

    execute("""
    UPDATE notification_intents
    SET status = 'retryable', claimed_at = NULL, next_attempt_at = NOW()
    WHERE status = 'delivering'
    """)

    execute("""
    UPDATE webhook_deliveries
    SET status = 'retryable', claimed_at = NULL, next_attempt_at = NOW()
    WHERE status = 'delivering'
    """)

    create(
      constraint(:attachments, :attachments_ready_requires_current_clean_version,
        check:
          "status <> 'ready' OR (scan_status = 'clean' AND object_version_id IS NOT NULL AND object_etag IS NOT NULL AND verified_checksum_sha256 IS NOT NULL AND verified_checksum_sha256 = checksum_sha256)"
      )
    )

    create(
      constraint(:attachments, :attachments_scan_claim_consistent,
        check:
          "(scan_status = 'scanning' AND scan_claim_token IS NOT NULL AND scan_claimed_at IS NOT NULL) OR (scan_status <> 'scanning' AND scan_claim_token IS NULL AND scan_claimed_at IS NULL)"
      )
    )

    create(
      constraint(:attachments, :attachments_scan_generation_non_negative,
        check: "scan_generation >= 0"
      )
    )

    create(
      constraint(:notification_intents, :notification_intents_claim_consistent,
        check:
          "(status = 'delivering' AND claim_token IS NOT NULL AND claimed_at IS NOT NULL) OR (status <> 'delivering' AND claim_token IS NULL AND claimed_at IS NULL)"
      )
    )

    create(
      constraint(:notification_intents, :notification_intents_claim_generation_non_negative,
        check: "claim_generation >= 0"
      )
    )

    create(
      constraint(:webhook_deliveries, :webhook_deliveries_claim_consistent,
        check:
          "(status = 'delivering' AND claim_token IS NOT NULL AND claimed_at IS NOT NULL) OR (status <> 'delivering' AND claim_token IS NULL AND claimed_at IS NULL)"
      )
    )

    create(
      constraint(:webhook_deliveries, :webhook_deliveries_claim_generation_non_negative,
        check: "claim_generation >= 0"
      )
    )

    create(
      constraint(:webhook_secret_versions, :webhook_secret_versions_crypto_shape,
        check:
          "octet_length(ciphertext) > 0 AND octet_length(nonce) = 12 AND octet_length(tag) = 16 AND key_id ~ '^[A-Za-z0-9_.-]{1,64}$'"
      )
    )
  end

  def down do
    drop(constraint(:webhook_secret_versions, :webhook_secret_versions_crypto_shape))

    drop(
      constraint(
        :webhook_deliveries,
        :webhook_deliveries_claim_generation_non_negative
      )
    )

    drop(constraint(:webhook_deliveries, :webhook_deliveries_claim_consistent))

    drop(
      constraint(
        :notification_intents,
        :notification_intents_claim_generation_non_negative
      )
    )

    drop(constraint(:notification_intents, :notification_intents_claim_consistent))
    drop(constraint(:attachments, :attachments_scan_generation_non_negative))
    drop(constraint(:attachments, :attachments_scan_claim_consistent))
    drop(constraint(:attachments, :attachments_ready_requires_current_clean_version))

    alter table(:webhook_secret_versions) do
      remove(:key_id)
    end

    alter table(:webhook_deliveries) do
      remove(:claim_token)
      remove(:claim_generation)
    end

    alter table(:notification_intents) do
      remove(:claim_token)
      remove(:claim_generation)
    end

    alter table(:attachments) do
      remove(:scan_claimed_at)
      remove(:scan_claim_token)
      remove(:scan_generation)
      remove(:verified_checksum_sha256)
      remove(:object_etag)
      remove(:object_version_id)
    end
  end
end
