defmodule CommsCore.Repo.Migrations.AddTelephonyVoicemail do
  use Ecto.Migration

  def up do
    create table(:telephony_mailboxes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id), null: false)
      add(:number_id, references(:telephony_numbers, type: :binary_id), null: false)
      add(:user_id, references(:users, type: :binary_id), null: false)
      add(:enabled, :boolean, null: false, default: false)
      add(:retention_days, :integer, null: false, default: 30)
      add(:notice_media, :text, null: false)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_mailboxes, [:number_id]))
    create(unique_index(:telephony_mailboxes, [:tenant_id, :id]))

    create(
      constraint(:telephony_mailboxes, :voicemail_retention_bounds,
        check: "retention_days BETWEEN 1 AND 90"
      )
    )

    execute(
      "ALTER TABLE telephony_mailboxes ADD CONSTRAINT voicemail_mailbox_tenant_number_fk FOREIGN KEY (tenant_id,number_id) REFERENCES telephony_numbers(tenant_id,id), ADD CONSTRAINT voicemail_mailbox_tenant_user_fk FOREIGN KEY (tenant_id,user_id) REFERENCES users(tenant_id,id)"
    )

    create table(:telephony_voicemails, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id), null: false)
      add(:mailbox_id, references(:telephony_mailboxes, type: :binary_id), null: false)
      add(:call_id, references(:telephony_calls, type: :binary_id), null: false)
      add(:user_id, references(:users, type: :binary_id), null: false)
      add(:recording_name, :text, null: false)
      add(:notice_media, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:duration_seconds, :integer)
      add(:retention_expires_at, :utc_datetime_usec, null: false)
      add(:recording_deadline, :utc_datetime_usec, null: false)
      add(:available_at, :utc_datetime_usec)
      add(:deleted_at, :utc_datetime_usec)
      add(:provider_deleted_at, :utc_datetime_usec)
      add(:object_key, :text)
      add(:object_version_id, :text)
      add(:object_etag, :text)
      add(:checksum_sha256, :text)
      add(:verified_checksum_sha256, :text)
      add(:byte_size, :integer)
      add(:content_type, :text, null: false, default: "audio/wav")
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_voicemails, [:call_id]))
    create(unique_index(:telephony_voicemails, [:recording_name]))
    create(unique_index(:telephony_voicemails, [:tenant_id, :id]))
    create(index(:telephony_voicemails, [:tenant_id, :user_id, :inserted_at]))
    create(index(:telephony_voicemails, [:retention_expires_at], where: "status <> 'deleted'"))

    create(
      constraint(:telephony_voicemails, :voicemail_status,
        check: "status IN ('pending','available','failed','deleting','deleted')"
      )
    )

    create(
      constraint(:telephony_voicemails, :voicemail_media_bounds,
        check:
          "content_type = 'audio/wav' AND (duration_seconds IS NULL OR duration_seconds BETWEEN 1 AND 120) AND (byte_size IS NULL OR byte_size BETWEEN 1 AND 8388608)"
      )
    )

    create(
      constraint(:telephony_voicemails, :voicemail_available_pinned,
        check:
          "status <> 'available' OR (object_version_id IS NOT NULL AND object_version_id NOT IN ('','null') AND object_etag IS NOT NULL AND checksum_sha256 IS NOT NULL AND verified_checksum_sha256 IS NOT NULL AND checksum_sha256 ~ '^[a-f0-9]{64}$' AND verified_checksum_sha256 = checksum_sha256 AND byte_size IS NOT NULL AND duration_seconds IS NOT NULL AND available_at IS NOT NULL)"
      )
    )

    execute(
      "ALTER TABLE telephony_voicemails ADD CONSTRAINT voicemail_tenant_mailbox_fk FOREIGN KEY (tenant_id,mailbox_id) REFERENCES telephony_mailboxes(tenant_id,id), ADD CONSTRAINT voicemail_tenant_call_fk FOREIGN KEY (tenant_id,call_id) REFERENCES telephony_calls(tenant_id,id), ADD CONSTRAINT voicemail_tenant_user_fk FOREIGN KEY (tenant_id,user_id) REFERENCES users(tenant_id,id)"
    )

    create table(:telephony_voicemail_reads, primary_key: false) do
      add(:voicemail_id, references(:telephony_voicemails, type: :binary_id),
        null: false,
        primary_key: true
      )

      add(:user_id, references(:users, type: :binary_id), null: false, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id), null: false)
      add(:read_at, :utc_datetime_usec, null: false)
    end

    execute(
      "ALTER TABLE telephony_voicemail_reads ADD CONSTRAINT voicemail_read_tenant_message_fk FOREIGN KEY (tenant_id,voicemail_id) REFERENCES telephony_voicemails(tenant_id,id), ADD CONSTRAINT voicemail_read_tenant_user_fk FOREIGN KEY (tenant_id,user_id) REFERENCES users(tenant_id,id)"
    )
  end

  def down do
    drop(table(:telephony_voicemail_reads))
    drop(table(:telephony_voicemails))
    drop(table(:telephony_mailboxes))
  end
end
