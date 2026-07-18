defmodule CommsCore.Repo.Migrations.AddAudioCallParticipants do
  use Ecto.Migration

  def up do
    create table(:audio_call_participants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :audio_call_id,
        references(:audio_calls, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id), null: false)
      add(:device_id, references(:devices, type: :binary_id), null: false)
      add(:session_id, references(:sessions, type: :binary_id), null: false)
      add(:provider_identity, :text, null: false)
      add(:status, :text, null: false, default: "admitted")
      add(:admitted_at, :utc_datetime_usec, null: false)
      add(:credential_issued_at, :utc_datetime_usec)
      add(:credential_issue_count, :integer, null: false, default: 0)
      add(:revoked_at, :utc_datetime_usec)
      add(:revocation_reason, :text)
      add(:eviction_status, :text, null: false, default: "not_required")
      add(:eviction_enforce_until, :utc_datetime_usec)
      add(:last_eviction_attempt_at, :utc_datetime_usec)
      add(:last_eviction_success_at, :utc_datetime_usec)
      add(:evicted_at, :utc_datetime_usec)
      add(:eviction_attempts, :integer, null: false, default: 0)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:audio_call_participants, [:tenant_id, :provider_identity],
        name: :audio_call_participants_provider_identity_unique
      )
    )

    create(
      unique_index(:audio_call_participants, [:audio_call_id, :session_id],
        where: "status = 'admitted'",
        name: :audio_call_participants_one_admission_per_call_session
      )
    )

    create(index(:audio_call_participants, [:tenant_id, :session_id]))
    create(index(:audio_call_participants, [:tenant_id, :device_id]))
    create(index(:audio_call_participants, [:tenant_id, :user_id]))
    create(index(:audio_call_participants, [:tenant_id, :conversation_id]))

    create(
      index(:audio_call_participants, [:eviction_status, :eviction_enforce_until],
        where: "eviction_status IN ('pending', 'enforcing')",
        name: :audio_call_participants_pending_eviction_index
      )
    )

    create(
      constraint(:audio_call_participants, :audio_call_participants_valid_status,
        check: "status IN ('admitted', 'revoked', 'evicted')"
      )
    )

    create(
      constraint(:audio_call_participants, :audio_call_participants_valid_eviction_status,
        check: "eviction_status IN ('not_required', 'pending', 'enforcing', 'completed')"
      )
    )

    create(
      constraint(:audio_call_participants, :audio_call_participants_issue_count_nonnegative,
        check: "credential_issue_count >= 0 AND eviction_attempts >= 0"
      )
    )

    create(
      constraint(:audio_call_participants, :audio_call_participants_state_consistent,
        check:
          "(status = 'admitted' AND revoked_at IS NULL AND revocation_reason IS NULL AND eviction_status = 'not_required' AND eviction_enforce_until IS NULL) OR " <>
            "(status IN ('revoked', 'evicted') AND revoked_at IS NOT NULL AND revocation_reason IS NOT NULL AND eviction_status IN ('pending', 'enforcing', 'completed') AND eviction_enforce_until IS NOT NULL)"
      )
    )

    execute("""
    ALTER TABLE audio_call_participants
    ADD CONSTRAINT audio_call_participants_tenant_call_fk
    FOREIGN KEY (tenant_id, audio_call_id) REFERENCES audio_calls (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT audio_call_participants_tenant_conversation_fk
    FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT audio_call_participants_tenant_user_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT audio_call_participants_tenant_device_fk
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    ADD CONSTRAINT audio_call_participants_tenant_session_fk
    FOREIGN KEY (tenant_id, session_id) REFERENCES sessions (tenant_id, id)
    """)
  end

  def down do
    drop(table(:audio_call_participants))
  end
end
