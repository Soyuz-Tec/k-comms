defmodule CommsCore.Release.HistoryCanonicalReleaseTest do
  use ExUnit.Case, async: false

  alias CommsCore.{MigrationFixture, Repo}

  @moduletag :integration
  @moduletag :release
  @source_paths [
    "apps/comms_core/lib/comms_core/repo.ex",
    "apps/comms_core/lib/comms_core/release/rollback_compatibility.ex",
    "apps/comms_core/lib/comms_core/release/migration.ex",
    "apps/comms_core/lib/comms_core/runtime_ports.ex",
    "apps/comms_core/priv/repo/migrations/20261006001300_add_conversation_favorites.exs",
    "apps/comms_workers/lib/comms_workers/audit_history_snapshot_purge_worker.ex",
    "apps/comms_core/priv/repo/migrations/20261006000100_index_resource_audit_history.exs",
    "apps/comms_core/test/support/migration_fixture.ex",
    "config/config.exs"
  ]

  test "actual canonical preflight preserves own full75 database while fencing every exact history worker job" do
    repository = Path.expand("../../../..", __DIR__)
    support = Path.expand("../support/history_canonical_release_probe.exs", __DIR__)
    source_paths = [__ENV__.file, support | Enum.map(@source_paths, &Path.join(repository, &1))]
    source_before = source_hashes(source_paths)

    # These are two cryptographically fresh, absence-checked databases. The
    # normal parent/focus Repo remains untouched; retain both proof databases.
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    template = "k_comms_history_template_" <> suffix
    database = "k_comms_history_rollback_" <> suffix
    artifact_directory = Path.join(System.tmp_dir!(), "k_comms_history_canonical_" <> suffix)
    File.mkdir!(artifact_directory)
    File.chmod!(artifact_directory, 0o700)
    migration_log = Path.join(artifact_directory, "full75-migration.log")
    probe_log = Path.join(artifact_directory, "canonical-probe.log")
    probe_receipt = Path.join(artifact_directory, "canonical-probe.json")
    parent_receipt = Path.join(artifact_directory, "subprocess-test.json")

    IO.puts(
      "History canonical retained databases: template=#{template} proof=#{database}; artifacts=#{artifact_directory}"
    )

    base = Repo.config()

    storage =
      Keyword.take(base, [:hostname, :port, :username, :password, :ssl, :ssl_opts, :socket_dir])

    admin_options =
      storage
      |> Keyword.put(:database, "postgres")
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:connect_timeout, 5_000)

    assert {:ok, admin} = Postgrex.start_link(admin_options)

    try do
      for name <- [template, database] do
        assert [[0]] =
                 Postgrex.query!(admin, "SELECT count(*) FROM pg_database WHERE datname=$1", [
                   name
                 ]).rows
      end

      assert :ok = Ecto.Adapters.Postgres.storage_up(Keyword.put(storage, :database, template))
      template_url = private_database_url(base, template)

      {migration_output, migration_status} =
        System.cmd("mix", ["ecto.migrate", "--no-compile"],
          cd: repository,
          env: [{"DATABASE_URL", template_url}, {"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 1:1"}],
          stderr_to_stdout: true
        )

      File.write!(migration_log, migration_output)
      File.chmod!(migration_log, 0o600)

      assert migration_status == 0,
             "fresh full75 migration failed; retained log: " <> migration_log

      assert :ok = MigrationFixture.await_no_peers(admin, template)

      assert [[0]] =
               Postgrex.query!(admin, "SELECT count(*) FROM pg_stat_activity WHERE datname=$1", [
                 template
               ]).rows

      assert [[0]] =
               Postgrex.query!(admin, "SELECT count(*) FROM pg_database WHERE datname=$1", [
                 database
               ]).rows

      assert :ok =
               Ecto.Adapters.Postgres.storage_up(
                 storage
                 |> Keyword.put(:database, database)
                 |> Keyword.put(:template, template)
               )
    after
      GenServer.stop(admin)
    end

    # Static central SQL resolves the named Core Repo. A separate --no-start
    # process starts that Repo against only this proof DB with ConnectionPool1;
    # it verifies actual peer count zero before invoking the public preflight.
    {probe_output, probe_status} =
      System.cmd("mix", ["run", "--no-start", "--no-compile", support, database],
        cd: repository,
        env: [
          {"DATABASE_URL", private_database_url(base, database)},
          {"K_COMMS_HISTORY_PROBE_RECEIPT", probe_receipt},
          {"MIX_ENV", "test"},
          {"ERL_FLAGS", "+S 1:1"}
        ],
        stderr_to_stdout: true
      )

    File.write!(probe_log, probe_output)
    File.chmod!(probe_log, 0o600)
    source_after = source_hashes(source_paths)

    File.write!(
      parent_receipt,
      Jason.encode!(
        %{
          template_database: template,
          proof_database: database,
          database_absence_verified: true,
          template_peer_count: 0,
          migration_log: migration_log,
          probe_log: probe_log,
          probe_receipt: probe_receipt,
          probe_exit: probe_status,
          source_before: source_before,
          source_after: source_after,
          source_bytes_unchanged: source_before == source_after,
          proof_databases_retained: true
        },
        pretty: true
      )
    )

    File.chmod!(parent_receipt, 0o600)
    if File.exists?(probe_receipt), do: File.chmod!(probe_receipt, 0o600)

    assert source_after == source_before

    assert probe_status == 0,
           "actual canonical history preflight failed; retained proof: " <> parent_receipt

    proof = probe_receipt |> File.read!() |> Jason.decode!()
    assert proof["database"] == database
    assert proof["migration_count"] == 75
    assert proof["peers"] == 0
    assert String.starts_with?(proof["application_name"], "k_comms/one_shot/")
    assert proof["source_bytes_unchanged"]
    assert proof["beam_bytes_unchanged"]
    assert proof["result"]["total"] == 11
    assert proof["result"]["failures"] == 0
    assert length(proof["cases"]) == 11

    assert Enum.all?(proof["cases"], fn evidence ->
             evidence["canonical_proof_complete"] and evidence["full_raw_snapshot_unchanged"] and
               evidence["before_sha256"] == evidence["after_sha256"] and
               Enum.sort(Map.keys(evidence["before_sha256"])) ==
                 ~w(history_rows jobs migration_versions schema_columns schema_constraints schema_indexes)
           end)

    expected_inputs =
      for kind <- ~w(cron continuation),
          state <- ~w(available scheduled executing retryable suspended),
          do: {kind, state}

    actual_inputs =
      proof["cases"]
      |> Enum.filter(&(&1["kind"] in ["cron", "continuation"]))
      |> Enum.map(&{&1["kind"], &1["state"]})

    assert Enum.sort(actual_inputs) == Enum.sort(expected_inputs)
    assert Enum.count(proof["cases"], &(&1["kind"] == "terminal_foreign_controls")) == 1
  end

  defp source_hashes(paths),
    do:
      Map.new(paths, &{&1, :crypto.hash(:sha256, File.read!(&1)) |> Base.encode16(case: :lower)})

  defp private_database_url(base, database) do
    %URI{
      scheme: "ecto",
      host: Keyword.get(base, :hostname, "localhost"),
      port: Keyword.get(base, :port, 5432),
      userinfo:
        URI.encode(Keyword.fetch!(base, :username), &URI.char_unreserved?/1) <>
          ":" <>
          URI.encode(Keyword.fetch!(base, :password), &URI.char_unreserved?/1),
      path: "/" <> database
    }
    |> URI.to_string()
  end
end
