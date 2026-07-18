defmodule CommsCore.Repo.Migrations.AddPushSubscriptions do
  use Ecto.Migration

  def up do
    create table(:push_subscriptions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false)
      add(:endpoint_hash, :binary, null: false)
      add(:endpoint_hint, :text, null: false)
      add(:version, :integer, null: false, default: 1)
      add(:ciphertext, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:tag, :binary, null: false)
      add(:key_id, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:expires_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:stale_at, :utc_datetime_usec)
      add(:last_materialized_at, :utc_datetime_usec)
      add(:disabled_reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:push_subscriptions, [:endpoint_hash],
        name: :push_subscriptions_endpoint_hash_unique
      )
    )

    create(
      unique_index(:push_subscriptions, [:tenant_id, :id],
        name: :push_subscriptions_tenant_id_id_unique
      )
    )

    create(
      index(:push_subscriptions, [:tenant_id, :user_id, :device_id, :status],
        name: :push_subscriptions_device_status_index
      )
    )

    create(
      index(:push_subscriptions, [:status, :expires_at],
        where: "status = 'active' AND expires_at IS NOT NULL",
        name: :push_subscriptions_active_expiration_index
      )
    )

    execute("""
    ALTER TABLE push_subscriptions
    ADD CONSTRAINT push_subscriptions_tenant_user_id_fk
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    ADD CONSTRAINT push_subscriptions_tenant_user_device_id_fk
    FOREIGN KEY (tenant_id, user_id, device_id) REFERENCES devices (tenant_id, user_id, id),
    ADD CONSTRAINT push_subscriptions_version_positive
    CHECK (version > 0),
    ADD CONSTRAINT push_subscriptions_endpoint_hash_shape
    CHECK (octet_length(endpoint_hash) = 32),
    ADD CONSTRAINT push_subscriptions_crypto_shape
    CHECK (octet_length(ciphertext) > 0 AND octet_length(nonce) = 12 AND octet_length(tag) = 16),
    ADD CONSTRAINT push_subscriptions_status_allowed
    CHECK (status IN ('active', 'revoked', 'expired', 'stale'))
    """)

    alter table(:notification_intents) do
      add(
        :push_subscription_id,
        references(:push_subscriptions, type: :binary_id, on_delete: :nilify_all)
      )

      add(:push_subscription_version, :integer)
    end

    execute("""
    ALTER TABLE notification_intents
    ADD CONSTRAINT notification_intents_push_subscription_shape
    CHECK (
      (push_subscription_id IS NULL AND push_subscription_version IS NULL) OR
      (push_subscription_id IS NOT NULL AND push_subscription_version > 0)
    )
    """)

    create(
      index(:notification_intents, [:tenant_id, :push_subscription_id],
        name: :notification_intents_push_subscription_index
      )
    )
  end

  def down do
    drop_if_exists(
      index(:notification_intents, [:tenant_id, :push_subscription_id],
        name: :notification_intents_push_subscription_index
      )
    )

    alter table(:notification_intents) do
      remove(:push_subscription_version)
      remove(:push_subscription_id)
    end

    drop(table(:push_subscriptions))
  end
end
