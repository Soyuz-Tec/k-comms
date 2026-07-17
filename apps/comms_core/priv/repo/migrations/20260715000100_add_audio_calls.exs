defmodule CommsCore.Repo.Migrations.AddAudioCalls do
  use Ecto.Migration

  def up do
    alter table(:tenant_settings) do
      add(:allow_audio_calls, :boolean, null: false, default: true)
    end

    create table(:audio_calls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :conversation_id,
        references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:started_by_user_id, references(:users, type: :binary_id), null: false)
      add(:ended_by_user_id, references(:users, type: :binary_id))
      add(:provider_room, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:started_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:end_reason, :text)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:audio_calls, [:tenant_id, :id], name: :audio_calls_tenant_id_id_unique))

    create(
      unique_index(:audio_calls, [:tenant_id, :provider_room],
        name: :audio_calls_tenant_provider_room_unique
      )
    )

    create(
      unique_index(:audio_calls, [:tenant_id, :conversation_id],
        where: "status = 'active'",
        name: :audio_calls_one_active_per_conversation
      )
    )

    create(index(:audio_calls, [:tenant_id, :expires_at], where: "status = 'active'"))

    create(
      constraint(:audio_calls, :audio_calls_valid_status, check: "status IN ('active', 'ended')")
    )

    create(
      constraint(:audio_calls, :audio_calls_bounded_expiry,
        check: "expires_at > started_at AND expires_at <= started_at + INTERVAL '8 hours'"
      )
    )

    create(
      constraint(:audio_calls, :audio_calls_end_state_consistent,
        check:
          "(status = 'active' AND ended_at IS NULL AND ended_by_user_id IS NULL AND end_reason IS NULL) OR " <>
            "(status = 'ended' AND ended_at IS NOT NULL AND end_reason IS NOT NULL)"
      )
    )

    execute("""
    ALTER TABLE audio_calls
    ADD CONSTRAINT audio_calls_tenant_conversation_fk
    FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT audio_calls_tenant_starter_fk
    FOREIGN KEY (tenant_id, started_by_user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT audio_calls_tenant_ender_fk
    FOREIGN KEY (tenant_id, ended_by_user_id) REFERENCES users (tenant_id, id)
    """)
  end

  def down do
    drop(table(:audio_calls))

    alter table(:tenant_settings) do
      remove(:allow_audio_calls)
    end
  end
end
