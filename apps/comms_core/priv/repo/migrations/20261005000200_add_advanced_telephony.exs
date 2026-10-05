defmodule CommsCore.Repo.Migrations.AddAdvancedTelephony do
  use Ecto.Migration

  def up do
    create table(:telephony_routes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:number_id, references(:telephony_numbers, type: :binary_id), null: false)
      add(:name, :text, null: false)
      add(:mode, :text, null: false)
      add(:policy, :text, null: false)
      add(:member_ids, {:array, :binary_id}, null: false, default: [])
      add(:max_waiting, :integer, null: false, default: 20)
      add(:max_wait_seconds, :integer, null: false, default: 120)
      add(:enabled, :boolean, null: false, default: false)
      add(:cursor, :integer, null: false, default: 0)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_routes, [:number_id]))
    create(unique_index(:telephony_routes, [:tenant_id, :id]))

    execute(
      "ALTER TABLE telephony_routes ADD CONSTRAINT telephony_route_tenant_number_fk FOREIGN KEY (tenant_id, number_id) REFERENCES telephony_numbers (tenant_id, id)"
    )

    create(
      constraint(:telephony_routes, :telephony_route_mode,
        check: "mode IN ('queue', 'shared_line') AND policy IN ('round_robin', 'simultaneous')"
      )
    )

    create(
      constraint(:telephony_routes, :telephony_route_bounds,
        check:
          "cardinality(member_ids) BETWEEN 1 AND 25 AND max_waiting BETWEEN 1 AND 100 AND max_wait_seconds BETWEEN 10 AND 600"
      )
    )

    alter table(:telephony_calls) do
      add(:route_id, references(:telephony_routes, type: :binary_id))
      add(:routing_status, :text, null: false, default: "individual")
      add(:offered_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:route_expires_at, :utc_datetime_usec)
      add(:control_state, :text, null: false, default: "connected")
      add(:pbx_state, :map, null: false, default: %{})
    end

    drop(
      index(:telephony_calls, [:tenant_id, :user_id], name: :telephony_calls_one_active_per_user)
    )

    create(
      unique_index(:telephony_calls, [:tenant_id, :user_id],
        where:
          "status IN ('ringing', 'answered') AND routing_status NOT IN ('waiting', 'voicemail')",
        name: :telephony_calls_one_active_per_user
      )
    )

    execute(
      "ALTER TABLE telephony_calls ADD CONSTRAINT telephony_call_tenant_route_fk FOREIGN KEY (tenant_id, route_id) REFERENCES telephony_routes (tenant_id, id)"
    )

    create(index(:telephony_calls, [:route_id, :routing_status, :started_at]))

    create table(:telephony_control_commands, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:call_id, references(:telephony_calls, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id), null: false)
      add(:session_id, references(:sessions, type: :binary_id))
      add(:device_id, references(:devices, type: :binary_id))
      add(:action, :text, null: false)
      add(:status, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:payload_hash, :text, null: false)
      add(:destination, :text)
      add(:claimed_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:failure_reason, :text)
      add(:notice_completed_at, :utc_datetime_usec)
      add(:notice_event_id, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_control_commands, [:call_id, :idempotency_key]))

    create(
      unique_index(:telephony_control_commands, [:notice_event_id],
        where: "notice_event_id IS NOT NULL"
      )
    )

    create(index(:telephony_control_commands, [:tenant_id, :call_id, :inserted_at]))

    create(
      constraint(:telephony_control_commands, :telephony_control_action,
        check:
          "action IN ('dtmf', 'blind_transfer', 'hold', 'resume', 'consult_transfer', 'complete_transfer', 'cancel_transfer', 'voicemail')"
      )
    )

    create(
      constraint(:telephony_control_commands, :telephony_control_actor,
        check:
          "(session_id IS NOT NULL AND device_id IS NOT NULL) OR (action = 'voicemail' AND session_id IS NULL AND device_id IS NULL)"
      )
    )

    create(
      constraint(:telephony_control_commands, :telephony_control_status,
        check: "status IN ('pending', 'dispatching', 'submitted', 'failed', 'unknown')"
      )
    )

    execute("""
    ALTER TABLE telephony_control_commands
    ADD CONSTRAINT telephony_control_tenant_call_fk FOREIGN KEY (tenant_id, call_id) REFERENCES telephony_calls (tenant_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT telephony_control_tenant_user_fk FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT telephony_control_tenant_session_fk FOREIGN KEY (tenant_id, session_id) REFERENCES sessions (tenant_id, id),
    ADD CONSTRAINT telephony_control_tenant_device_fk FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id)
    """)
  end

  def down do
    drop(table(:telephony_control_commands))
    execute("ALTER TABLE telephony_calls DROP CONSTRAINT telephony_call_tenant_route_fk")

    drop(
      index(:telephony_calls, [:tenant_id, :user_id], name: :telephony_calls_one_active_per_user)
    )

    alter table(:telephony_calls) do
      remove(:route_id)
      remove(:routing_status)
      remove(:offered_user_ids)
      remove(:route_expires_at)
      remove(:control_state)
      remove(:pbx_state)
    end

    drop(table(:telephony_routes))

    create(
      unique_index(:telephony_calls, [:tenant_id, :user_id],
        where: "status IN ('ringing', 'answered')",
        name: :telephony_calls_one_active_per_user
      )
    )
  end
end
