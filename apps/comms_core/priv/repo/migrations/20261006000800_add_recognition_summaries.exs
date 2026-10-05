defmodule CommsCore.Repo.Migrations.AddRecognitionSummaries do
  use Ecto.Migration

  def up do
    alter table(:call_artifacts) do
      add(:summary_requested, :boolean, null: false, default: false)
      add(:summary_source_sha256, :text)
      add(:summary_provider_claimed_at, :utc_datetime_usec)
      add(:summary_claim_fingerprint, :text)
      add(:summary_effect_started_at, :utc_datetime_usec)
      add(:recognition_provider_id, :text)
      add(:recognition_model_sha256, :text)
      add(:recognition_source_sha256, :text)
    end

    alter table(:call_artifact_consents) do
      add(:summary_accepted, :boolean, null: false, default: false)
      add(:summary_policy_version, :text)
      add(:summary_decided_at, :utc_datetime_usec)
    end

    drop(constraint(:call_artifacts, :call_artifacts_valid_kind))

    create(
      constraint(:call_artifacts, :call_artifacts_valid_kind,
        check: "kind IN ('recording','transcript','summary')"
      )
    )

    drop(constraint(:call_artifacts, :call_artifacts_ready_identity))

    create(
      constraint(:call_artifacts, :call_artifacts_ready_identity,
        check:
          "status != 'available' OR (kind IN ('transcript','summary') AND source_artifact_id IS NOT NULL) OR (kind = 'recording' AND object_version_id IS NOT NULL AND checksum_sha256 IS NOT NULL AND byte_size > 0 AND object_etag IS NOT NULL)"
      )
    )

    create(
      constraint(:call_artifacts, :call_artifacts_summary_proof,
        check:
          "kind != 'summary' OR (summary_requested AND source_artifact_id IS NOT NULL AND summary_source_sha256 IS NOT NULL AND summary_source_sha256 ~ '^[a-f0-9]{64}$' AND (summary_provider_claimed_at IS NULL OR (summary_claim_fingerprint IS NOT NULL AND summary_claim_fingerprint ~ '^[a-f0-9]{64}$' AND summary_effect_started_at IS NOT NULL)))"
      )
    )

    create(
      constraint(:call_artifact_consents, :call_artifact_summary_disclosure,
        check:
          "NOT summary_accepted OR (summary_policy_version IS NOT NULL AND summary_policy_version = 'meeting-summary-v1' AND summary_decided_at IS NOT NULL)"
      )
    )

    create(
      unique_index(:call_artifacts, [:source_artifact_id],
        name: :call_artifacts_one_summary_per_transcript,
        where: "kind = 'summary'"
      )
    )

    create(
      unique_index(:call_artifacts, [:tenant_id, :id], name: :call_artifacts_tenant_identity)
    )

    create table(:call_artifact_summaries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :uuid, null: false)
      add(:artifact_id, :uuid, null: false)
      add(:source_artifact_id, :uuid, null: false)
      add(:source_sha256, :text, null: false)
      add(:summary_sha256, :text, null: false)
      add(:policy_version, :text, null: false)
      add(:provider_id, :text, null: false)
      add(:provider_model, :text, null: false)
      add(:text, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:call_artifact_summaries, [:artifact_id]))

    execute(
      "ALTER TABLE call_artifact_summaries ADD CONSTRAINT call_summary_artifact_tenant_fk FOREIGN KEY (tenant_id,artifact_id) REFERENCES call_artifacts(tenant_id,id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE call_artifact_summaries ADD CONSTRAINT call_summary_source_tenant_fk FOREIGN KEY (tenant_id,source_artifact_id) REFERENCES call_artifacts(tenant_id,id) ON DELETE RESTRICT"
    )

    create(
      constraint(:call_artifact_summaries, :call_summary_bounds,
        check:
          "source_sha256 ~ '^[a-f0-9]{64}$' AND summary_sha256 ~ '^[a-f0-9]{64}$' AND policy_version = 'meeting-summary-v1' AND octet_length(text) BETWEEN 1 AND 16384 AND octet_length(provider_id) BETWEEN 1 AND 200 AND octet_length(provider_model) BETWEEN 1 AND 128"
      )
    )
  end

  def down do
    # Metadata, revoked consent decisions, and orphan active jobs all retain the
    # new capability; a down migration is never an implicit privacy cleanup.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM call_artifact_summaries) OR
         EXISTS (SELECT 1 FROM call_artifacts WHERE kind = 'summary' OR summary_requested OR summary_source_sha256 IS NOT NULL OR summary_provider_claimed_at IS NOT NULL OR summary_claim_fingerprint IS NOT NULL OR summary_effect_started_at IS NOT NULL OR recognition_provider_id IS NOT NULL OR recognition_model_sha256 IS NOT NULL OR recognition_source_sha256 IS NOT NULL) OR
         EXISTS (SELECT 1 FROM call_artifact_consents WHERE summary_accepted OR summary_policy_version IS NOT NULL OR summary_decided_at IS NOT NULL) OR
         EXISTS (SELECT 1 FROM oban_jobs WHERE worker = 'CommsWorkers.CallSummaryWorker' AND state IN ('available','scheduled','executing','retryable','suspended')) THEN
        RAISE EXCEPTION 'uc_recognition_summaries_v1 retained state or active jobs prevents downgrade';
      END IF;
    END $$;
    """)

    drop(table(:call_artifact_summaries))
    drop(index(:call_artifacts, [:tenant_id, :id], name: :call_artifacts_tenant_identity))

    drop(
      index(:call_artifacts, [:source_artifact_id],
        name: :call_artifacts_one_summary_per_transcript
      )
    )

    drop(constraint(:call_artifact_consents, :call_artifact_summary_disclosure))
    drop(constraint(:call_artifacts, :call_artifacts_summary_proof))
    drop(constraint(:call_artifacts, :call_artifacts_valid_kind))

    create(
      constraint(:call_artifacts, :call_artifacts_valid_kind,
        check: "kind IN ('recording','transcript')"
      )
    )

    drop(constraint(:call_artifacts, :call_artifacts_ready_identity))

    create(
      constraint(:call_artifacts, :call_artifacts_ready_identity,
        check:
          "status != 'available' OR (kind = 'transcript' AND source_artifact_id IS NOT NULL) OR (object_version_id IS NOT NULL AND checksum_sha256 IS NOT NULL AND byte_size > 0 AND object_etag IS NOT NULL)"
      )
    )

    alter table(:call_artifacts) do
      remove(:summary_requested)
      remove(:summary_source_sha256)
      remove(:summary_provider_claimed_at)
      remove(:summary_claim_fingerprint)
      remove(:summary_effect_started_at)
      remove(:recognition_provider_id)
      remove(:recognition_model_sha256)
      remove(:recognition_source_sha256)
    end

    alter table(:call_artifact_consents) do
      remove(:summary_accepted)
      remove(:summary_policy_version)
      remove(:summary_decided_at)
    end
  end
end
