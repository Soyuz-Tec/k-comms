defmodule CommsCore.WebhookSecretMigrationTest.MigrationRepo do
  use Ecto.Repo,
    otp_app: :comms_core,
    adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.WebhookSecretMigrationTest do
  use ExUnit.Case, async: false

  alias CommsCore.WebhookSecretMigrationTest.MigrationRepo
  alias Ecto.Adapters.SQL

  @legacy_schema_version 20_260_712_000_330
  @context_bound_schema_version 20_260_713_000_110

  setup do
    database =
      "k_comms_legacy_upgrade_" <>
        (Ecto.UUID.generate() |> String.replace("-", ""))

    base_config = CommsCore.Repo.config()

    storage_config =
      base_config
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.put(:database, database)

    repo_config =
      storage_config
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(
        :migration_primary_key,
        Keyword.fetch!(base_config, :migration_primary_key)
      )
      |> Keyword.put(
        :migration_foreign_key,
        Keyword.fetch!(base_config, :migration_foreign_key)
      )

    assert :ok = Ecto.Adapters.Postgres.storage_up(storage_config)
    assert {:ok, repo} = MigrationRepo.start_link(repo_config)
    Process.unlink(repo)

    previous_compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(previous_compiler_options)
      if Process.alive?(repo), do: GenServer.stop(repo)
      assert :ok = Ecto.Adapters.Postgres.storage_down(storage_config)
    end)

    %{repo: MigrationRepo}
  end

  test "rotated legacy ciphertext is purged and outstanding delivery is terminalized", %{
    repo: repo
  } do
    migrate_to(repo, @legacy_schema_version)
    fixture = seed_rotated_legacy_endpoint(repo, :pending)

    migrate_to(repo, @context_bound_schema_version)

    assert [[0]] =
             rows(repo, "SELECT count(*) FROM webhook_secret_versions WHERE key_id = 'legacy'")

    assert [[1]] =
             rows(repo, "SELECT count(*) FROM webhook_secret_versions WHERE key_id = 'primary'")

    assert [["failed", "legacy_secret_requires_rotation"]] =
             rows(
               repo,
               "SELECT status, last_error_code FROM webhook_deliveries WHERE id = $1::text::uuid",
               [fixture.outstanding_delivery_id]
             )

    assert [["delivered"]] =
             rows(
               repo,
               "SELECT status FROM webhook_deliveries WHERE id = $1::text::uuid",
               [fixture.delivered_delivery_id]
             )

    assert_raise Postgrex.Error, fn ->
      insert_secret(repo, fixture, 3, "legacy", nil)
    end
  end

  test "migration refuses an unrotated current legacy secret", %{repo: repo} do
    migrate_to(repo, @legacy_schema_version)
    fixture = seed_current_legacy_endpoint(repo)

    error =
      assert_raise Postgrex.Error, fn ->
        migrate_to(repo, @context_bound_schema_version)
      end

    assert Exception.message(error) =~ "current legacy webhook secrets must be rotated"

    assert [[1]] =
             rows(repo, "SELECT count(*) FROM webhook_secret_versions WHERE key_id = 'legacy'")

    assert [[1]] =
             rows(
               repo,
               "SELECT secret_version FROM webhook_endpoints WHERE id = $1::text::uuid",
               [fixture.endpoint_id]
             )
  end

  test "migration refuses every in-flight legacy delivery regardless of claim age", %{
    repo: repo
  } do
    migrate_to(repo, @legacy_schema_version)
    fixture = seed_rotated_legacy_endpoint(repo, :delivering)

    SQL.query!(
      repo,
      "UPDATE webhook_deliveries SET claimed_at = NOW() - INTERVAL '1 day' WHERE id = $1::text::uuid",
      [fixture.outstanding_delivery_id]
    )

    error =
      assert_raise Postgrex.Error, fn ->
        migrate_to(repo, @context_bound_schema_version)
      end

    assert Exception.message(error) =~ "legacy webhook deliveries must leave delivering state"

    assert [["delivering"]] =
             rows(
               repo,
               "SELECT status FROM webhook_deliveries WHERE id = $1::text::uuid",
               [fixture.outstanding_delivery_id]
             )

    assert [[1]] =
             rows(repo, "SELECT count(*) FROM webhook_secret_versions WHERE key_id = 'legacy'")
  end

  defp migrate_to(repo, version) do
    Ecto.Migrator.run(repo, migrations_path(), :up, to: version, log: false)
  end

  defp migrations_path do
    Application.app_dir(:comms_core, "priv/repo/migrations")
  end

  defp seed_current_legacy_endpoint(repo) do
    fixture = seed_identity_and_endpoint(repo, 1)
    insert_secret(repo, fixture, 1, "legacy", nil)
    fixture
  end

  defp seed_rotated_legacy_endpoint(repo, outstanding_status) do
    fixture = seed_identity_and_endpoint(repo, 2)
    insert_secret(repo, fixture, 1, "legacy", DateTime.utc_now())
    insert_secret(repo, fixture, 2, "primary", nil)

    outstanding_delivery_id = Ecto.UUID.generate()
    delivered_delivery_id = Ecto.UUID.generate()

    insert_delivery(repo, fixture, outstanding_delivery_id, outstanding_status)
    insert_delivery(repo, fixture, delivered_delivery_id, :delivered)

    Map.merge(fixture, %{
      outstanding_delivery_id: outstanding_delivery_id,
      delivered_delivery_id: delivered_delivery_id
    })
  end

  defp seed_identity_and_endpoint(repo, secret_version) do
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    endpoint_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO tenants (id, name, slug, status, inserted_at, updated_at)
      VALUES ($1::text::uuid, 'Legacy upgrade tenant', $2, 'active', NOW(), NOW())
      """,
      [tenant_id, "legacy-upgrade-#{String.slice(tenant_id, 0, 8)}"]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO users (
        id, tenant_id, external_subject, display_name, email, status, role,
        lock_version, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3, 'Legacy owner', $4, 'active', 'owner',
        1, NOW(), NOW()
      )
      """,
      [user_id, tenant_id, "legacy-owner-#{user_id}", "legacy-#{user_id}@example.test"]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO webhook_endpoints (
        id, tenant_id, name, url, status, secret_version, created_by_user_id,
        inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, 'Legacy endpoint', 'https://hooks.example.test/events',
        'active', $3, $4::text::uuid, NOW(), NOW()
      )
      """,
      [endpoint_id, tenant_id, secret_version, user_id]
    )

    %{tenant_id: tenant_id, endpoint_id: endpoint_id}
  end

  defp insert_secret(repo, fixture, version, key_id, retired_at) do
    SQL.query!(
      repo,
      """
      INSERT INTO webhook_secret_versions (
        id, tenant_id, endpoint_id, version, ciphertext, nonce, tag, key_id,
        retired_at, inserted_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid, $4,
        decode(repeat('01', 16), 'hex'),
        decode(repeat('02', 12), 'hex'),
        decode(repeat('03', 16), 'hex'),
        $5, $6, NOW()
      )
      """,
      [
        Ecto.UUID.generate(),
        fixture.tenant_id,
        fixture.endpoint_id,
        version,
        key_id,
        retired_at
      ]
    )
  end

  defp insert_delivery(repo, fixture, delivery_id, status) do
    delivering? = status == :delivering
    delivered? = status == :delivered

    SQL.query!(
      repo,
      """
      INSERT INTO webhook_deliveries (
        id, tenant_id, endpoint_id, event_type, payload, idempotency_key,
        secret_version, status, attempt_count, next_attempt_at, claimed_at,
        delivered_at, claim_generation, claim_token, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid, 'message.created.v1', '{}'::jsonb, $4,
        1, $5, 0, NOW(),
        CASE WHEN $6 THEN NOW() ELSE NULL END,
        CASE WHEN $7 THEN NOW() ELSE NULL END,
        CASE WHEN $6 THEN 1 ELSE 0 END,
        CASE WHEN $6 THEN $8::text::uuid ELSE NULL END,
        NOW(), NOW()
      )
      """,
      [
        delivery_id,
        fixture.tenant_id,
        fixture.endpoint_id,
        "legacy-delivery-#{delivery_id}",
        Atom.to_string(status),
        delivering?,
        delivered?,
        Ecto.UUID.generate()
      ]
    )
  end

  defp rows(repo, statement, parameters \\ []) do
    SQL.query!(repo, statement, parameters).rows
  end
end
