defmodule CommsCore.Repo.Migrations.AddTelephony do
  use Ecto.Migration

  def up do
    create table(:telephony_room_tombstones, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:room_hash, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_room_tombstones, [:room_hash]))
    create(index(:telephony_room_tombstones, [:expires_at]))

    create table(:telephony_numbers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id), null: false)
      add(:phone_number, :text, null: false)
      add(:extension, :text, null: false)
      add(:inbound_trunk_id, :text, null: false)
      add(:outbound_trunk_id, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_numbers, [:tenant_id]))
    create(unique_index(:telephony_numbers, [:phone_number]))
    create(unique_index(:telephony_numbers, [:tenant_id, :id]))

    execute("""
    ALTER TABLE telephony_numbers ADD CONSTRAINT telephony_numbers_tenant_user_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id)
    """)

    create(
      constraint(:telephony_numbers, :telephony_numbers_e164,
        check: "phone_number ~ '^\\+[1-9][0-9]{7,14}$'"
      )
    )

    create table(:telephony_calls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:number_id, references(:telephony_numbers, type: :binary_id), null: false)
      add(:user_id, references(:users, type: :binary_id), null: false)
      add(:direction, :text, null: false)
      add(:status, :text, null: false, default: "ringing")
      add(:from_number, :text, null: false)
      add(:to_number, :text, null: false)
      add(:extension, :text, null: false)
      add(:inbound_trunk_id, :text, null: false)
      add(:outbound_trunk_id, :text, null: false)
      add(:provider_room, :text, null: false)
      add(:provider_identity, :text, null: false)
      add(:provider_call_id, :text)
      add(:idempotency_key, :text)
      add(:answer_session_id, :binary_id)
      add(:answer_device_id, :binary_id)
      add(:app_identity, :text)
      add(:app_connected_at, :utc_datetime_usec)
      add(:app_reconnect_deadline, :utc_datetime_usec)
      add(:app_provider_sid, :text)
      add(:app_left_sid, :text)
      add(:app_event_at, :utc_datetime_usec)
      add(:app_pending_sid, :text)
      add(:app_pending_at, :utc_datetime_usec)
      add(:dispatch_status, :text, null: false, default: "pending")
      add(:dispatch_claimed_at, :utc_datetime_usec)
      add(:cleanup_claimed_at, :utc_datetime_usec)
      add(:cleanup_completed_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:answered_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:end_reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_calls, [:tenant_id, :id]))
    create(unique_index(:telephony_calls, [:provider_room]))

    create(
      unique_index(:telephony_calls, [:tenant_id, :user_id, :idempotency_key],
        where: "idempotency_key IS NOT NULL"
      )
    )

    create(
      unique_index(:telephony_calls, [:tenant_id, :user_id],
        where: "status IN ('ringing', 'answered')",
        name: :telephony_calls_one_active_per_user
      )
    )

    create(index(:telephony_calls, [:tenant_id, :user_id, :started_at, :id]))

    execute("""
    ALTER TABLE telephony_calls
    ADD CONSTRAINT telephony_calls_tenant_number_fk
    FOREIGN KEY (tenant_id, number_id) REFERENCES telephony_numbers (tenant_id, id),
    ADD CONSTRAINT telephony_calls_tenant_user_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT telephony_calls_tenant_session_fk
    FOREIGN KEY (tenant_id, answer_session_id) REFERENCES sessions (tenant_id, id),
    ADD CONSTRAINT telephony_calls_tenant_device_fk
    FOREIGN KEY (tenant_id, answer_device_id) REFERENCES devices (tenant_id, id)
    """)

    create(
      constraint(:telephony_calls, :telephony_calls_valid_direction,
        check: "direction IN ('inbound', 'outbound')"
      )
    )

    create(
      constraint(:telephony_calls, :telephony_calls_valid_status,
        check:
          "status IN ('ringing', 'answered', 'declined', 'no_answer', 'cancelled', 'failed', 'ended', 'busy')"
      )
    )

    create(
      constraint(:telephony_calls, :telephony_calls_consistent_outcome,
        check:
          "(status IN ('ringing', 'answered') AND ended_at IS NULL AND end_reason IS NULL) OR (status NOT IN ('ringing', 'answered') AND ended_at IS NOT NULL AND end_reason IS NOT NULL)"
      )
    )

    create(
      constraint(:telephony_calls, :telephony_calls_consistent_times,
        check:
          "expires_at > started_at AND (answered_at IS NULL OR answered_at >= started_at) AND (ended_at IS NULL OR ended_at >= started_at) AND (answered_at IS NULL OR ended_at IS NULL OR ended_at >= answered_at)"
      )
    )

    create table(:telephony_provider_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:call_id, references(:telephony_calls, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_id, :text, null: false)
      add(:event_type, :text, null: false)
      add(:participant_sid, :text)
      add(:occurred_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:telephony_provider_events, [:event_id]))
    create(index(:telephony_provider_events, [:call_id, :participant_sid, :event_type]))

    execute("""
    ALTER TABLE telephony_provider_events ADD CONSTRAINT telephony_events_tenant_call_fk
    FOREIGN KEY (tenant_id, call_id) REFERENCES telephony_calls (tenant_id, id) ON DELETE CASCADE
    """)
  end

  def down do
    drop(table(:telephony_provider_events))
    drop(table(:telephony_calls))
    drop(table(:telephony_numbers))
    drop_if_exists(table(:telephony_room_tombstones))
  end
end
