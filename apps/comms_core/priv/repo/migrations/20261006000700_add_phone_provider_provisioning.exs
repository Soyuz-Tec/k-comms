defmodule CommsCore.Repo.Migrations.AddPhoneProviderProvisioning do
  use Ecto.Migration

  def up do
    alter table(:telephony_numbers) do
      add(:lock_version, :integer, null: false, default: 1)
    end

    create table(:telephony_provisioning_commands, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:actor_user_id, :binary_id, null: false)
      add(:actor_device_id, :binary_id, null: false)
      add(:actor_session_id, :binary_id, null: false)
      add(:request_id, :binary_id, null: false)
      add(:assignment_version, :integer, null: false)
      add(:desired, :map, null: false)
      add(:snapshot, :map, null: false, default: %{})
      add(:status, :text, null: false)
      add(:failure_reason, :text)
      add(:effect_consumed, :boolean, null: false, default: false)
      add(:lease_hash, :binary)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telephony_provisioning_commands, [:tenant_id, :request_id]))
    create(index(:telephony_provisioning_commands, [:tenant_id, :inserted_at]))

    create(
      constraint(:telephony_provisioning_commands, :telephony_provisioning_command_status,
        check:
          "status IN ('inspecting','verified','applying','unknown','applied','failed','reconciling')"
      )
    )

    create(
      constraint(:telephony_provisioning_commands, :telephony_provisioning_command_version,
        check: "version > 0 AND assignment_version >= 0"
      )
    )
  end

  def down do
    # Effect receipts are required to reconcile an uncertain external create.
    raise "phone provider receipts must be retained; disable management and reconcile effects before rollback"
  end
end
