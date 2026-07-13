defmodule CommsCore.Repo.Migrations.RequireContextBoundWebhookSecrets do
  use Ecto.Migration

  def up do
    execute("""
    LOCK TABLE webhook_endpoints,
               webhook_secret_versions,
               webhook_deliveries
    IN SHARE ROW EXCLUSIVE MODE
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM webhook_secret_versions AS secret
        JOIN webhook_endpoints AS endpoint
          ON endpoint.id = secret.endpoint_id
         AND endpoint.tenant_id = secret.tenant_id
        WHERE secret.key_id = 'legacy'
          AND (
            secret.retired_at IS NULL OR
            secret.version = endpoint.secret_version
          )
      ) THEN
        RAISE EXCEPTION
          'current legacy webhook secrets must be rotated before applying the context-bound secret migration';
      END IF;
    END
    $$
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM webhook_deliveries AS delivery
        JOIN webhook_secret_versions AS secret
          ON secret.tenant_id = delivery.tenant_id
         AND secret.endpoint_id = delivery.endpoint_id
         AND secret.version = delivery.secret_version
        WHERE secret.key_id = 'legacy'
          AND delivery.status = 'delivering'
      ) THEN
        RAISE EXCEPTION
          'legacy webhook deliveries must leave delivering state before applying the context-bound secret migration';
      END IF;
    END
    $$
    """)

    execute("""
    UPDATE webhook_deliveries AS delivery
    SET status = 'failed',
        claimed_at = NULL,
        claim_token = NULL,
        last_error_code = 'legacy_secret_requires_rotation',
        updated_at = NOW()
    FROM webhook_secret_versions AS secret
    WHERE secret.key_id = 'legacy'
      AND delivery.tenant_id = secret.tenant_id
      AND delivery.endpoint_id = secret.endpoint_id
      AND delivery.secret_version = secret.version
      AND delivery.status NOT IN ('delivered', 'delivering')
    """)

    execute("DELETE FROM webhook_secret_versions WHERE key_id = 'legacy'")

    execute("ALTER TABLE webhook_secret_versions ALTER COLUMN key_id DROP DEFAULT")

    create(
      constraint(:webhook_secret_versions, :webhook_secret_versions_context_bound_key,
        check: "key_id <> 'legacy'"
      )
    )
  end

  def down do
    drop(
      constraint(
        :webhook_secret_versions,
        :webhook_secret_versions_context_bound_key
      )
    )

    execute(
      "ALTER TABLE webhook_secret_versions ALTER COLUMN key_id SET DEFAULT 'legacy'"
    )
  end
end
