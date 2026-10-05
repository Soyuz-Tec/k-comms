defmodule CommsCore.Repo.Migrations.AddWorkspaceDomainDiscovery do
  use Ecto.Migration

  def up do
    create table(:workspace_domain_claims, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :delete_all), null: false)
      add(:challenge_actor_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:domain, :string, size: 253, null: false)
      add(:challenge_token, :string, size: 64)
      add(:challenge_expires_at, :utc_datetime_usec, null: false)
      add(:verified_at, :utc_datetime_usec)
      add(:proof_expires_at, :utc_datetime_usec)
      add(:discovery_enabled, :boolean, null: false, default: false)
      add(:status, :string, null: false, default: "pending")
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:workspace_domain_claims, [:tenant_id, :domain]))

    execute("""
    ALTER TABLE workspace_domain_claims
      ADD CONSTRAINT workspace_domain_claim_actor_tenant_fkey
      FOREIGN KEY (tenant_id, challenge_actor_user_id) REFERENCES users(tenant_id, id);
    """)

    create(
      unique_index(:workspace_domain_claims, [:domain],
        name: :workspace_domain_claims_verified_domain_index,
        where: "status = 'verified'"
      )
    )

    create(
      constraint(:workspace_domain_claims, :workspace_domain_claim_shape,
        check: """
        version > 0 AND status IN ('pending', 'verified', 'expired')
        AND domain = lower(domain) AND domain ~ '^[a-z0-9.-]+$'
        AND (challenge_token IS NULL OR challenge_token ~ '^[A-Za-z0-9_-]{43}$')
        AND (status <> 'verified' OR
          (verified_at IS NOT NULL AND proof_expires_at > verified_at
           AND proof_expires_at <= verified_at + interval '7 days'))
        """
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM workspace_domain_claims LIMIT 1) THEN
        RAISE EXCEPTION 'workspace domain migration rollback refused: retained domain claims';
      END IF;
    END $$;
    """)

    drop(table(:workspace_domain_claims))
  end
end
