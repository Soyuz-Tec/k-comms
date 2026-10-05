defmodule CommsCore.Conversations.FederationMigrationTest.MigrationRepo do
  use Ecto.Repo, otp_app: :comms_core, adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.Conversations.FederationMigrationTest do
  use ExUnit.Case, async: false

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Conversations.Federation.{Command, EventReceipt, Participant, Room, Trust}
  alias CommsCore.Conversations.FederationMigrationTest.MigrationRepo, as: R
  alias Ecto.Adapters.SQL

  @moduletag :integration
  @moduletag :migration
  @version 20_261_006_000_900
  @tables ~w(federation_trusts federation_rooms federation_participants federation_commands federation_event_receipts)
  @retained_cases [
    {"federation_trusts", []},
    {"federation_rooms", ["federation_trusts"]},
    {"federation_participants", ["federation_trusts", "federation_rooms"]},
    {"federation_commands", ["federation_trusts", "federation_rooms"]},
    {"federation_event_receipts", ["federation_trusts", "federation_rooms"]}
  ]

  setup_all do
    # 00900 has only Federation-owned foreign keys. Run that exact migration in
    # a new database; neither the parent nor the focus database is migrated here.
    database =
      "k_comms_federation_migration_" <>
        Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    base = Repo.config()

    storage =
      base
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :ssl_opts, :socket_dir])
      |> Keyword.put(:database, database)

    admin_options =
      storage
      |> Keyword.put(:database, "postgres")
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:connect_timeout, 5_000)

    assert {:ok, admin} = Postgrex.start_link(admin_options)

    try do
      assert [[0]] =
               Postgrex.query!(
                 admin,
                 "SELECT count(*)::bigint FROM pg_database WHERE datname = $1",
                 [database],
                 timeout: 5_000
               ).rows

      assert :ok = Ecto.Adapters.Postgres.storage_up(storage)

      IO.puts(
        "Federation migration database retained: #{database}; absence_count=0; " <>
          "migration=20261006000900; pool=DBConnection.ConnectionPool"
      )
    after
      GenServer.stop(admin)
    end

    config =
      storage
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:timeout, 15_000)
      |> Keyword.put(:connect_timeout, 5_000)
      |> Keyword.put(:parameters, statement_timeout: "15000", lock_timeout: "5000")
      |> Keyword.put(:migration_primary_key, Keyword.fetch!(base, :migration_primary_key))
      |> Keyword.put(:migration_foreign_key, Keyword.fetch!(base, :migration_foreign_key))

    assert {:ok, pid} = R.start_link(config)
    Process.unlink(pid)

    # Intentionally retain the database, including failed qualification evidence.
    # The only row cleanup below is by UUIDs inserted by this test file.
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert [[^database]] = SQL.query!(R, "SELECT current_database()", []).rows
    assert public_tables() == []

    path =
      Application.app_dir(
        :comms_core,
        "priv/repo/migrations/20261006000900_add_federation.exs"
      )

    migration = Module.concat(["CommsCore", "Repo", "Migrations", "AddFederation"])
    unless Code.ensure_loaded?(migration), do: Code.require_file(path)
    assert :ok = Ecto.Migrator.up(R, @version, migration, log: false)

    %{database: database, repo_pid: pid, migration_module: migration}
  end

  setup %{database: database} do
    assert [[^database]] = SQL.query!(R, "SELECT current_database()", []).rows
    assert public_tables() == Enum.sort(["schema_migrations" | @tables])
    assert Ecto.Migrator.migrated_versions(R) == [@version]
    assert Enum.all?(raw_snapshot(), fn {_table, result} -> result.rows == [] end)
    :ok
  end

  test "actual empty 00900 down and up recreate only its five owner tables", %{
    migration_module: migration,
    repo_pid: pid,
    database: database
  } do
    assert federation_hazard_count(pid, database) == 0
    assert :ok = Ecto.Migrator.down(R, @version, migration, log: false)
    assert public_tables() == ["schema_migrations"]
    assert Ecto.Migrator.migrated_versions(R) == []

    assert :ok = Ecto.Migrator.up(R, @version, migration, log: false)
    assert public_tables() == Enum.sort(["schema_migrations" | @tables])
    assert Ecto.Migrator.migrated_versions(R) == [@version]
    assert Enum.all?(raw_snapshot(), fn {_table, result} -> result.rows == [] end)
    assert federation_hazard_count(pid, database) == 0
  end

  for {table, dependencies} <- @retained_cases do
    @tag retained_table: table, dependency_tables: dependencies
    test "actual 00900 down preserves retained #{table} and its required dependencies", %{
      retained_table: table,
      dependency_tables: dependencies,
      migration_module: migration,
      repo_pid: pid,
      database: database
    } do
      # A valid child row needs Trust/Room parents. These cases qualify the actual
      # refusal with that explicit dependency state, not impossible orphan rows or
      # an assertion that a child's disjunct alone triggered the guard.
      fixture = seed_fixture(table)
      on_exit(fn -> delete_fixture(fixture) end)
      expected_tables = Enum.sort([table | dependencies])
      before = raw_snapshot()

      assert Enum.sort(Map.keys(fixture)) == expected_tables

      assert Map.new(before, fn {name, result} -> {name, length(result.rows)} end) ==
               Map.new(@tables, &{&1, if(&1 in expected_tables, do: 1, else: 0)})

      assert federation_hazard_count(pid, database) == length(expected_tables)

      assert_raise Postgrex.Error,
                   ~r/Federation rollback refused: retained consent, mappings, commands or deletion uncertainty/,
                   fn -> Ecto.Migrator.down(R, @version, migration, log: false) end

      assert raw_snapshot() == before
      assert Ecto.Migrator.migrated_versions(R) == [@version]
      assert public_tables() == Enum.sort(["schema_migrations" | @tables])
      assert federation_hazard_count(pid, database) == length(expected_tables)
    end
  end

  defp seed_fixture(target) do
    tenant_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    trust =
      R.insert!(%Trust{
        id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        domain: "remote.example.org",
        residency: "Synthetic migration region",
        cross_border_reason: "Retained synthetic rollback qualification",
        enabled: false
      })

    rows = %{"federation_trusts" => trust}

    rows =
      if target == "federation_trusts" do
        rows
      else
        room =
          R.insert!(%Room{
            id: Ecto.UUID.generate(),
            tenant_id: tenant_id,
            conversation_id: Ecto.UUID.generate(),
            trust_id: trust.id,
            alias_localpart: "kc_fed_migration_" <> String.replace(trust.id, "-", ""),
            provider_issuer: "https://matrix.example.org",
            provider_server_name: "example.org",
            provider_bridge_user: "@bridge:example.org",
            provider_room_box: :crypto.strong_rand_bytes(48),
            status: "fenced",
            generation: 2,
            fenced_at: now,
            remote_cleanup_state: "remote_unconfirmed"
          })

        Map.put(rows, "federation_rooms", room)
      end

    case target do
      "federation_participants" ->
        row =
          R.insert!(%Participant{
            id: Ecto.UUID.generate(),
            tenant_id: tenant_id,
            room_id: rows["federation_rooms"].id,
            principal_hash: random_hash(),
            principal_box: :crypto.strong_rand_bytes(48),
            consent_status: "withdrawn",
            withdrawn_at: now
          })

        Map.put(rows, target, row)

      "federation_commands" ->
        row =
          R.insert!(%Command{
            id: Ecto.UUID.generate(),
            tenant_id: tenant_id,
            room_id: rows["federation_rooms"].id,
            request_key: "retained:" <> Ecto.UUID.generate(),
            payload_digest: random_hash(),
            kind: "redact",
            status: "done",
            generation: 2,
            expected_room_version: 1,
            attempts: 2,
            provider_receipt_box: :crypto.strong_rand_bytes(48)
          })

        Map.put(rows, target, row)

      "federation_event_receipts" ->
        row =
          R.insert!(%EventReceipt{
            id: Ecto.UUID.generate(),
            tenant_id: tenant_id,
            room_id: rows["federation_rooms"].id,
            event_hash: random_hash(),
            provider_event_box: :crypto.strong_rand_bytes(48),
            sender_hash: random_hash(),
            observed_at: now,
            redacted_observed_at: now
          })

        Map.put(rows, target, row)

      _ ->
        rows
    end
  end

  defp federation_hazard_count(pid, database) do
    previous = Repo.get_dynamic_repo()

    try do
      # Ecto resolves dynamic Repo pids across Repo modules. This routing changes
      # only this test process and is restored even if the facade raises.
      Repo.put_dynamic_repo(pid)
      assert [[^database]] = Repo.query!("SELECT current_database()", []).rows
      Conversations.rollback_federation_hazard_count()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp raw_snapshot do
    Map.new(@tables, fn table ->
      result = SQL.query!(R, "SELECT * FROM #{table} ORDER BY id", [])
      {table, %{columns: result.columns, rows: result.rows}}
    end)
  end

  defp public_tables do
    SQL.query!(
      R,
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY tablename",
      []
    ).rows
    |> Enum.map(&hd/1)
  end

  defp delete_fixture(fixture) do
    for table <- Enum.reverse(@tables), record = Map.get(fixture, table), not is_nil(record) do
      assert %{num_rows: 1} =
               SQL.query!(R, "DELETE FROM #{table} WHERE id = $1::text::uuid", [record.id])
    end
  end

  defp random_hash,
    do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
end
