defmodule CommsCore.Repo.Migrations.AddIntegrationsSafetyOperations do
  use Ecto.Migration

  def up do
    create(unique_index(:attachments, [:tenant_id, :id], name: :attachments_tenant_id_id_unique))

    create(
      unique_index(:outbox_events, [:tenant_id, :id], name: :outbox_events_tenant_id_id_unique)
    )

    alter table(:attachments) do
      add(:scan_status, :text, null: false, default: "pending")
      add(:scan_verdict, :text)
      add(:scan_provider, :text)
      add(:scan_attempts, :integer, null: false, default: 0)
      add(:scan_error_code, :text)
      add(:scanned_at, :utc_datetime_usec)
      add(:quarantined_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE attachments
    SET status = 'quarantined',
        scan_status = 'pending',
        scan_verdict = 'legacy_unscanned',
        quarantined_at = NOW()
    WHERE status = 'ready'
    """)

    create(
      constraint(:attachments, :attachments_scan_status_allowed,
        check: "scan_status IN ('pending', 'scanning', 'clean', 'blocked', 'failed')"
      )
    )

    create(
      constraint(:attachments, :attachments_status_allowed,
        check:
          "status IN ('pending', 'uploaded', 'ready', 'quarantined', 'scan_failed', 'deleted')"
      )
    )

    create(index(:attachments, [:tenant_id, :scan_status, :inserted_at]))

    create table(:attachment_scan_attempts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :attachment_id,
        references(:attachments, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:attempt_number, :integer, null: false)
      add(:provider, :text, null: false)
      add(:status, :text, null: false)
      add(:verdict, :text)
      add(:error_code, :text)
      add(:provider_reference, :text)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:attachment_scan_attempts, [:attachment_id, :attempt_number]))
    create(index(:attachment_scan_attempts, [:tenant_id, :inserted_at]))

    create(
      constraint(:attachment_scan_attempts, :attachment_scan_attempts_status_allowed,
        check: "status IN ('clean', 'blocked', 'retryable', 'failed')"
      )
    )

    create table(:notification_preferences, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:email_enabled, :boolean, null: false, default: true)
      add(:push_enabled, :boolean, null: false, default: false)
      add(:in_app_enabled, :boolean, null: false, default: true)
      add(:muted_event_types, {:array, :text}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:notification_preferences, [:tenant_id, :user_id]))

    create table(:notification_intents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:event_type, :text, null: false)
      add(:channel, :text, null: false)
      add(:destination, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:idempotency_key, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
      add(:claimed_at, :utc_datetime_usec)
      add(:delivered_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:notification_intents, [:tenant_id, :idempotency_key]))

    create(
      unique_index(:notification_intents, [:tenant_id, :id],
        name: :notification_intents_tenant_id_id_unique
      )
    )

    create(index(:notification_intents, [:tenant_id, :user_id, :inserted_at]))
    create(index(:notification_intents, [:status, :next_attempt_at]))

    create(
      constraint(:notification_intents, :notification_intents_channel_allowed,
        check: "channel IN ('email', 'push', 'in_app')"
      )
    )

    create(
      constraint(:notification_intents, :notification_intents_status_allowed,
        check: "status IN ('pending', 'delivering', 'retryable', 'delivered', 'failed')"
      )
    )

    create(
      constraint(:notification_intents, :notification_intents_attempts_non_negative,
        check: "attempt_count >= 0"
      )
    )

    create table(:notification_attempts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :intent_id,
        references(:notification_intents, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:attempt_number, :integer, null: false)
      add(:provider, :text, null: false)
      add(:status, :text, null: false)
      add(:http_status, :integer)
      add(:error_code, :text)
      add(:provider_message_id, :text)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:notification_attempts, [:intent_id, :attempt_number]))
    create(index(:notification_attempts, [:tenant_id, :inserted_at]))

    create(
      constraint(:notification_attempts, :notification_attempts_status_allowed,
        check: "status IN ('delivered', 'retryable', 'failed')"
      )
    )

    create table(:webhook_endpoints, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :text, null: false)
      add(:url, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:secret_version, :integer, null: false, default: 1)
      add(:created_by_user_id, references(:users, type: :binary_id), null: false)
      add(:disabled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:webhook_endpoints, [:tenant_id, :name]))

    create(
      unique_index(:webhook_endpoints, [:tenant_id, :id],
        name: :webhook_endpoints_tenant_id_id_unique
      )
    )

    create(index(:webhook_endpoints, [:tenant_id, :status]))

    create(
      constraint(:webhook_endpoints, :webhook_endpoints_status_allowed,
        check: "status IN ('active', 'disabled')"
      )
    )

    create(
      constraint(:webhook_endpoints, :webhook_endpoints_secret_version_positive,
        check: "secret_version > 0"
      )
    )

    create table(:webhook_subscriptions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :endpoint_id,
        references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:webhook_subscriptions, [:endpoint_id, :event_type]))
    create(index(:webhook_subscriptions, [:tenant_id, :event_type]))

    create table(:webhook_secret_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :endpoint_id,
        references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:version, :integer, null: false)
      add(:ciphertext, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:tag, :binary, null: false)
      add(:retired_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:webhook_secret_versions, [:endpoint_id, :version]))

    create table(:webhook_deliveries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :endpoint_id,
        references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :outbox_event_id,
        references(:outbox_events, type: :binary_id, on_delete: :nilify_all)
      )

      add(:event_type, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:idempotency_key, :text, null: false)
      add(:secret_version, :integer, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
      add(:claimed_at, :utc_datetime_usec)
      add(:last_attempt_at, :utc_datetime_usec)
      add(:delivered_at, :utc_datetime_usec)
      add(:response_status, :integer)
      add(:last_error_code, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:webhook_deliveries, [:tenant_id, :idempotency_key]))
    create(index(:webhook_deliveries, [:tenant_id, :endpoint_id, :inserted_at]))
    create(index(:webhook_deliveries, [:status, :next_attempt_at]))

    create(
      constraint(:webhook_deliveries, :webhook_deliveries_status_allowed,
        check: "status IN ('pending', 'delivering', 'retryable', 'delivered', 'failed')"
      )
    )

    create(
      constraint(:webhook_deliveries, :webhook_deliveries_attempts_non_negative,
        check: "attempt_count >= 0"
      )
    )

    add_tenant_constraint(:attachment_scan_attempts, :attachment_id, :attachments)
    add_tenant_constraint(:notification_preferences, :user_id, :users)
    add_tenant_constraint(:notification_intents, :user_id, :users)
    add_tenant_constraint(:notification_attempts, :intent_id, :notification_intents)
    add_tenant_constraint(:webhook_endpoints, :created_by_user_id, :users)
    add_tenant_constraint(:webhook_subscriptions, :endpoint_id, :webhook_endpoints)
    add_tenant_constraint(:webhook_secret_versions, :endpoint_id, :webhook_endpoints)
    add_tenant_constraint(:webhook_deliveries, :endpoint_id, :webhook_endpoints)
    add_tenant_constraint(:webhook_deliveries, :outbox_event_id, :outbox_events)
  end

  def down do
    drop(table(:webhook_deliveries))
    drop(table(:webhook_secret_versions))
    drop(table(:webhook_subscriptions))
    drop(table(:webhook_endpoints))
    drop(table(:notification_attempts))
    drop(table(:notification_intents))
    drop(table(:notification_preferences))
    drop(table(:attachment_scan_attempts))

    drop_if_exists(index(:attachments, [:tenant_id, :scan_status, :inserted_at]))
    drop(constraint(:attachments, :attachments_status_allowed))
    drop(constraint(:attachments, :attachments_scan_status_allowed))

    alter table(:attachments) do
      remove(:scan_status)
      remove(:scan_verdict)
      remove(:scan_provider)
      remove(:scan_attempts)
      remove(:scan_error_code)
      remove(:scanned_at)
      remove(:quarantined_at)
    end

    drop_if_exists(
      index(:outbox_events, [:tenant_id, :id], name: :outbox_events_tenant_id_id_unique)
    )

    drop_if_exists(index(:attachments, [:tenant_id, :id], name: :attachments_tenant_id_id_unique))
  end

  defp add_tenant_constraint(table, foreign_column, target) do
    constraint_name = "#{table}_tenant_#{foreign_column}_fk"

    execute("""
    ALTER TABLE #{table}
    ADD CONSTRAINT #{constraint_name}
    FOREIGN KEY (tenant_id, #{foreign_column}) REFERENCES #{target} (tenant_id, id)
    """)
  end
end
