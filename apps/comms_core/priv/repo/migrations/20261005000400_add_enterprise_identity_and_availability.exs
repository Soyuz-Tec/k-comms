defmodule CommsCore.Repo.Migrations.AddEnterpriseIdentityAndAvailability do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE service_accounts DROP CONSTRAINT service_accounts_scopes_allowed, ADD CONSTRAINT service_accounts_scopes_allowed CHECK (cardinality(scopes) > 0 AND scopes <@ ARRAY['conversations:read', 'messages:read', 'messages:write', 'search:read', 'scim:read', 'scim:write']::text[])",
      "ALTER TABLE service_accounts DROP CONSTRAINT service_accounts_scopes_allowed, ADD CONSTRAINT service_accounts_scopes_allowed CHECK (cardinality(scopes) > 0 AND scopes <@ ARRAY['conversations:read', 'messages:read', 'messages:write', 'search:read']::text[])"
    )

    alter table(:users) do
      add(:avatar_url, :text)
      add(:timezone, :string, null: false, default: "Etc/UTC")
      add(:presence_state, :string, null: false, default: "available")
      add(:presence_expires_at, :utc_datetime_usec)
      add(:dnd_until, :utc_datetime_usec)
      add(:dnd_schedule, :map, null: false, default: %{})
    end

    alter table(:sessions) do
      add(:mfa_verified_at, :utc_datetime_usec)
      add(:authentication_method, :string, null: false, default: "password")
    end

    create table(:identity_mfa_factors, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:ciphertext, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:tag, :binary, null: false)
      add(:key_id, :string, null: false)
      add(:enabled_at, :utc_datetime_usec)
      add(:last_used_step, :bigint, null: false, default: -1)
      add(:recovery_hashes, {:array, :binary}, null: false, default: [])
      add(:failed_attempts, :integer, null: false, default: 0)
      add(:locked_until, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:identity_mfa_factors, [:tenant_id, :user_id]))

    create table(:identity_auth_challenges, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all))
      add(:kind, :string, null: false)
      add(:token_hash, :binary, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:attempts, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:identity_auth_challenges, [:token_hash]))
    create(index(:identity_auth_challenges, [:expires_at]))

    create table(:federated_identities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:issuer, :text, null: false)
      add(:subject, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:federated_identities, [:tenant_id, :issuer, :subject]))
    create(unique_index(:federated_identities, [:tenant_id, :user_id, :issuer]))

    create table(:scim_directory_resources, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all))
      add(:kind, :string, null: false)
      add(:external_id, :string, null: false)
      add(:display_name, :string, null: false)
      add(:members, {:array, :uuid}, null: false, default: [])
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:scim_directory_resources, [:tenant_id, :kind, :external_id]))
    create(unique_index(:scim_directory_resources, [:user_id], where: "user_id IS NOT NULL"))
  end
end
