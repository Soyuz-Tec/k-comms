defmodule CommsCore.Repo.Migrations.AddBoundedIvrAndAgentState do
  use Ecto.Migration

  def up do
    create table(:telephony_ivr_menus, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:number_id, references(:telephony_numbers, type: :binary_id), null: false)
      add(:name, :text, null: false)
      add(:prompt_media, :text, null: false)
      add(:choices, :map, null: false)
      add(:fallback, :map, null: false)
      add(:digit_timeout_seconds, :integer, null: false, default: 10)
      add(:max_retries, :integer, null: false, default: 1)
      add(:enabled, :boolean, null: false, default: false)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_ivr_menus, [:number_id]))
    create(unique_index(:telephony_ivr_menus, [:tenant_id, :id]))

    execute("""
    ALTER TABLE telephony_ivr_menus ADD CONSTRAINT telephony_ivr_menu_number_fk FOREIGN KEY (tenant_id, number_id) REFERENCES telephony_numbers (tenant_id, id)
    """)

    create(
      constraint(:telephony_ivr_menus, :telephony_ivr_menu_bounds,
        check:
          "length(name) BETWEEN 1 AND 100 AND " <>
            "prompt_media ~ '^sound:[A-Za-z0-9_/-]{1,150}$' AND " <>
            "digit_timeout_seconds BETWEEN 5 AND 30 AND max_retries BETWEEN 0 AND 2 " <>
            "AND version > 0 AND octet_length(choices::text) <= 8192 " <>
            "AND octet_length(fallback::text) <= 1024"
      )
    )

    create table(:telephony_ivr_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:call_id, references(:telephony_calls, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:menu_id, references(:telephony_ivr_menus, type: :binary_id), null: false)
      add(:menu_version, :integer, null: false)
      add(:snapshot, :map, null: false)
      add(:phase, :text, null: false, default: "pending")
      add(:step, :integer, null: false, default: 1)
      add(:retries, :integer, null: false, default: 0)
      add(:selected_target, :map)
      add(:bindings, :map, null: false, default: %{})
      add(:claimed_at, :utc_datetime_usec)
      add(:effect_claim_fingerprint, :text)
      add(:effect_started_at, :utc_datetime_usec)
      add(:prompt_completed_at, :utc_datetime_usec)
      add(:digit_deadline, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:completed_at, :utc_datetime_usec)
      add(:failure_reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_ivr_runs, [:call_id]))
    create(unique_index(:telephony_ivr_runs, [:tenant_id, :id]))
    create(index(:telephony_ivr_runs, [:tenant_id, :phase, :expires_at]))

    execute("""
    ALTER TABLE telephony_ivr_runs ADD CONSTRAINT telephony_ivr_run_call_fk FOREIGN KEY (tenant_id, call_id) REFERENCES telephony_calls (tenant_id, id)
    """)

    execute("""
    ALTER TABLE telephony_ivr_runs ADD CONSTRAINT telephony_ivr_run_menu_fk FOREIGN KEY (tenant_id, menu_id) REFERENCES telephony_ivr_menus (tenant_id, id)
    """)

    create(
      constraint(:telephony_ivr_runs, :telephony_ivr_run_bounds,
        check:
          "phase IN ('pending','preparing','playing','awaiting_digit','selected','routing'," <>
            "'destination_pending','destination_connecting','unknown','completed','failed','cancelled') " <>
            "AND step BETWEEN 1 AND 3 AND retries BETWEEN 0 AND 2 AND menu_version > 0 " <>
            "AND octet_length(snapshot::text) <= 12288 AND octet_length(bindings::text) <= 4096 " <>
            "AND (digit_deadline IS NULL OR digit_deadline <= expires_at) " <>
            "AND (phase <> 'awaiting_digit' OR (prompt_completed_at IS NOT NULL AND digit_deadline IS NOT NULL)) " <>
            "AND (effect_claim_fingerprint IS NULL OR effect_claim_fingerprint ~ '^[0-9a-f]{64}$') " <>
            "AND (completed_at IS NULL OR completed_at >= inserted_at)"
      )
    )

    create table(:telephony_ivr_event_receipts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:run_id, references(:telephony_ivr_runs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_id, :text, null: false)
      add(:body_fingerprint, :text, null: false)
      add(:step, :integer, null: false)
      add(:event_type, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:telephony_ivr_event_receipts, [:event_id]))
    create(index(:telephony_ivr_event_receipts, [:run_id]))

    execute("""
    ALTER TABLE telephony_ivr_event_receipts ADD CONSTRAINT telephony_ivr_receipt_run_fk FOREIGN KEY (tenant_id, run_id) REFERENCES telephony_ivr_runs (tenant_id, id)
    """)

    create(
      constraint(:telephony_ivr_event_receipts, :telephony_ivr_receipt_bounds,
        check:
          "event_id ~ '^[0-9a-f]{64}$' AND body_fingerprint ~ '^[0-9a-f]{64}$' " <>
            "AND step BETWEEN 1 AND 3 AND event_type IN ('PlaybackFinished','ChannelDtmfReceived','ChannelDestroyed')"
      )
    )

    create table(:telephony_agent_states, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:state, :text, null: false, default: "ready")
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_agent_states, [:tenant_id, :user_id]))

    execute("""
    ALTER TABLE telephony_agent_states ADD CONSTRAINT telephony_agent_state_tenant_user_fk FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id)
    """)

    create(
      constraint(:telephony_agent_states, :telephony_agent_state_bounds,
        check:
          "state IN ('ready','away','wrap_up') AND version > 0 AND " <>
            "expires_at > updated_at AND expires_at <= updated_at + interval '1 hour'"
      )
    )

    # IVR callers wait independently of agent offers. They stay subject to the
    # owner admission cap and unchanged call deadline; they are never browser
    # answer candidates until the existing route atomically selects an agent.
    drop(
      index(:telephony_calls, [:tenant_id, :user_id], name: :telephony_calls_one_active_per_user)
    )

    create(
      unique_index(:telephony_calls, [:tenant_id, :user_id],
        where:
          "status IN ('ringing', 'answered') AND routing_status NOT IN ('waiting', 'voicemail', 'ivr', 'ivr_destination')",
        name: :telephony_calls_one_active_per_user
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM telephony_ivr_menus)
         OR EXISTS (SELECT 1 FROM telephony_ivr_runs)
         OR EXISTS (SELECT 1 FROM telephony_ivr_event_receipts)
         OR EXISTS (SELECT 1 FROM telephony_agent_states)
         OR EXISTS (SELECT 1 FROM telephony_calls WHERE routing_status IN ('ivr', 'ivr_destination'))
         OR EXISTS (SELECT 1 FROM oban_jobs WHERE worker = 'CommsWorkers.TelephonyIvrWorker'
                    AND state::text IN ('available', 'scheduled', 'executing', 'retryable', 'suspended')) THEN
        RAISE EXCEPTION 'IVR or agent state is retained; destructive rollback is prohibited';
      END IF;
    END $$;
    """)

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

    drop(table(:telephony_agent_states))
    drop(table(:telephony_ivr_event_receipts))
    drop(table(:telephony_ivr_runs))
    drop(table(:telephony_ivr_menus))
  end
end
