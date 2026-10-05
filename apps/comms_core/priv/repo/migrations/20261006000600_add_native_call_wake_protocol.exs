defmodule CommsCore.Repo.Migrations.AddNativeCallWakeProtocol do
  use Ecto.Migration

  def up do
    create table(:native_push_registrations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, :binary_id, null: false)
      add(:device_id, :binary_id, null: false)
      add(:session_id, references(:sessions, type: :binary_id), null: false)
      add(:installation_id, :binary_id, null: false)
      add(:user_version, :integer, null: false)
      add(:platform, :text, null: false)
      add(:channel, :text, null: false)
      add(:application_id, :text, null: false)
      add(:environment, :text, null: false)
      add(:version, :integer, null: false, default: 1)
      add(:token_hash, :binary, null: false)
      add(:ciphertext, :binary)
      add(:nonce, :binary)
      add(:tag, :binary)
      add(:key_id, :text)
      add(:status, :text, null: false, default: "active")
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:disabled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:native_push_registrations, [:tenant_id, :id]))

    create(
      unique_index(
        :native_push_registrations,
        [:platform, :channel, :application_id, :environment, :token_hash],
        name: :native_push_token_unique
      )
    )

    create(
      unique_index(:native_push_registrations, [:tenant_id, :user_id, :device_id, :channel],
        name: :native_push_device_channel_unique
      )
    )

    create(index(:native_push_registrations, [:tenant_id, :session_id, :status]))
    create(index(:native_push_registrations, [:status, :expires_at]))

    execute("""
    ALTER TABLE native_push_registrations
    ADD CONSTRAINT native_push_session_tenant_fk FOREIGN KEY (tenant_id, session_id) REFERENCES sessions (tenant_id, id),
    ADD CONSTRAINT native_push_user_fk FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT native_push_device_fk FOREIGN KEY (tenant_id, user_id, device_id) REFERENCES devices (tenant_id, user_id, id),
    ADD CONSTRAINT native_push_versions CHECK (version > 0 AND user_version > 0),
    ADD CONSTRAINT native_push_token_shape CHECK (octet_length(token_hash) = 32),
    ADD CONSTRAINT native_push_crypto CHECK ((status = 'active' AND ciphertext IS NOT NULL AND nonce IS NOT NULL AND tag IS NOT NULL AND octet_length(ciphertext) > 0 AND octet_length(nonce) = 12 AND octet_length(tag) = 16 AND key_id IS NOT NULL) OR (status != 'active' AND ciphertext IS NULL AND nonce IS NULL AND tag IS NULL AND key_id IS NULL)),
    ADD CONSTRAINT native_push_status CHECK (status IN ('active','revoked','expired','stale')),
    ADD CONSTRAINT native_push_channel CHECK ((platform = 'ios' AND channel IN ('apns_alert','apns_voip') AND environment IN ('sandbox','production')) OR (platform = 'android' AND channel = 'fcm' AND environment = 'production'))
    """)

    create table(:native_call_wakes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, :binary_id, null: false)
      add(:device_id, :binary_id, null: false)
      add(:session_id, :binary_id, null: false)

      add(
        :registration_id,
        references(:native_push_registrations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:registration_version, :integer, null: false)
      add(:user_version, :integer, null: false)
      add(:owner, :text, null: false)
      add(:call_id, :binary_id, null: false)
      add(:conversation_id, :binary_id)
      add(:source_event_id, :binary_id, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:attempted_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:consumed_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:native_call_wakes, [:registration_id, :registration_version, :call_id],
        name: :native_call_wake_generation_unique
      )
    )

    create(index(:native_call_wakes, [:tenant_id, :session_id, :status]))
    create(index(:native_call_wakes, [:status, :expires_at]))

    execute("""
    ALTER TABLE native_call_wakes
    ADD CONSTRAINT native_wake_registration_tenant_fk FOREIGN KEY (tenant_id, registration_id) REFERENCES native_push_registrations (tenant_id, id),
    ADD CONSTRAINT native_wake_owner CHECK ((owner = 'conversation' AND conversation_id IS NOT NULL) OR (owner = 'telephony' AND conversation_id IS NULL)),
    ADD CONSTRAINT native_wake_status CHECK (status IN ('pending','dispatching','sent','uncertain','consumed','expired','revoked','failed')),
    ADD CONSTRAINT native_wake_versions CHECK (registration_version > 0 AND user_version > 0),
    ADD CONSTRAINT native_wake_horizon CHECK (expires_at <= inserted_at + interval '30 seconds')
    """)
  end

  def down do
    # Refuse before any DDL, including when jobs outlive or never referenced a
    # retained intent. Quiesced rollback counts exact workers and active states.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM native_push_registrations) OR
         EXISTS (SELECT 1 FROM native_call_wakes) OR
         EXISTS (SELECT 1 FROM oban_jobs WHERE worker IN ('CommsWorkers.NativeCallWakeWorker','CommsWorkers.NativePushReconcilerWorker') AND state IN ('available','scheduled','executing','retryable')) THEN
        RAISE EXCEPTION 'native_call_wake_v1 retained state or active jobs require a compatible binary or verified owner erasure';
      END IF;
    END $$
    """)

    drop(table(:native_call_wakes))
    drop(table(:native_push_registrations))
  end
end
