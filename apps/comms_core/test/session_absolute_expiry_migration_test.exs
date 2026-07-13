defmodule CommsCore.SessionAbsoluteExpiryMigrationTest.MigrationRepo do
  use Ecto.Repo,
    otp_app: :comms_core,
    adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.SessionAbsoluteExpiryMigrationTest do
  use ExUnit.Case, async: false

  alias CommsCore.SessionAbsoluteExpiryMigrationTest.MigrationRepo
  alias Ecto.Adapters.SQL

  @absolute_expiry_schema_version 20_260_713_000_120
  @rollback_compatibility_schema_version 20_260_713_000_130

  setup do
    database =
      "k_comms_session_rollback_" <>
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

  test "reconciles and preserves the previous-release session insert default", %{repo: repo} do
    migrate_to(repo, @absolute_expiry_schema_version)
    fixture = seed_identity(repo)

    assert_previous_release_insert(repo, fixture)

    SQL.query!(
      repo,
      "ALTER TABLE sessions ALTER COLUMN absolute_expires_at DROP DEFAULT"
    )

    assert_raise Postgrex.Error, ~r/null value in column "absolute_expires_at"/, fn ->
      insert_previous_release_session(repo, fixture)
    end

    migrate_to(repo, @rollback_compatibility_schema_version)
    assert_previous_release_insert(repo, fixture)

    Ecto.Migrator.run(repo, migrations_path(), :down, step: 1, log: false)
    assert_previous_release_insert(repo, fixture)
  end

  defp migrate_to(repo, version) do
    Ecto.Migrator.run(repo, migrations_path(), :up, to: version, log: false)
  end

  defp migrations_path do
    Application.app_dir(:comms_core, "priv/repo/migrations")
  end

  defp seed_identity(repo) do
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    device_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO tenants (id, name, slug, status, inserted_at, updated_at)
      VALUES ($1::text::uuid, 'Rollback tenant', $2, 'active', NOW(), NOW())
      """,
      [tenant_id, "rollback-#{String.slice(tenant_id, 0, 8)}"]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO users (
        id, tenant_id, external_subject, display_name, email, status,
        inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3, 'Rollback user', $4, 'active',
        NOW(), NOW()
      )
      """,
      [user_id, tenant_id, "rollback-user-#{user_id}", "rollback-#{user_id}@example.test"]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO devices (
        id, tenant_id, user_id, name, platform, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid,
        'Rollback browser', 'test', NOW(), NOW()
      )
      """,
      [device_id, tenant_id, user_id]
    )

    %{tenant_id: tenant_id, user_id: user_id, device_id: device_id}
  end

  defp assert_previous_release_insert(repo, fixture) do
    assert [[true, true]] = insert_previous_release_session(repo, fixture)
  end

  defp insert_previous_release_session(repo, fixture) do
    inserted_at =
      DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)

    expires_at = NaiveDateTime.add(inserted_at, 600, :second)

    repo.transaction(fn ->
      SQL.query!(repo, "SET LOCAL TIME ZONE 'Asia/Kolkata'")

      SQL.query!(
        repo,
        """
        INSERT INTO sessions (
          id, tenant_id, user_id, device_id, refresh_token_hash,
          expires_at, last_used_at, inserted_at, updated_at
        )
        VALUES (
          $1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5,
          $6::timestamp, $7::timestamp, $7::timestamp, $7::timestamp
        )
        RETURNING
          absolute_expires_at =
            (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '30 days',
          absolute_expires_at > expires_at
        """,
        [
          Ecto.UUID.generate(),
          fixture.tenant_id,
          fixture.user_id,
          fixture.device_id,
          :crypto.strong_rand_bytes(32),
          expires_at,
          inserted_at
        ]
      ).rows
    end)
    |> case do
      {:ok, rows} -> rows
      {:error, error} -> raise error
    end
  end
end
