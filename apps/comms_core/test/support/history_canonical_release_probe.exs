# Run in a dedicated process with an owner-prepared, fresh full75 database:
# MIX_ENV=test DATABASE_URL=<private binding> mix run --no-start --no-compile \
#   apps/comms_core/test/support/history_canonical_release_probe.exs <exact-owned-database-name>
# Set K_COMMS_HISTORY_PROBE_RECEIPT to distinct negative/green JSON paths.
# No application, Oban queue, HTTP server, or provider is started. Keep this
# database after the proof; only exact fixture job IDs are removed between cases.
ExUnit.start(autorun: false)
ExUnit.configure(seed: 960_079, max_cases: 1)

defmodule FullUc.HistoryCanonicalReleaseProbe do
  use ExUnit.Case, async: false
  alias CommsCore.{Audit, Release, Repo, RuntimePorts}

  @m1_capabilities ~w(
    guest_identity_v1 guest_admission_expiry_worker_v1
    instant_room_lifecycle_v1 instant_room_presence_lease_v1
    instant_room_expiry_worker_v1 conversation_only_human_v1
    enterprise_identity_v1 uc_artifact_lifecycle_v1 uc_voicemail_lifecycle_v1
    uc_advanced_telephony_v1 scheduled_meeting_lifecycle_v1 rich_content_erasure_v1
  )
  @states ~w(available scheduled executing retryable suspended)
  @terminal_states ~w(completed discarded cancelled)

  setup_all do
    [expected_database] = System.argv()

    assert expected_database =~
             ~r/\Ak_comms_(history_rollback|full_uc_integration)_[a-f0-9]{16,32}\z/

    url = System.fetch_env!("DATABASE_URL")
    receipt_path = System.fetch_env!("K_COMMS_HISTORY_PROBE_RECEIPT")
    assert is_nil(Process.whereis(Repo)), "dedicated --no-start process is required"

    for app <- [:crypto, :ecto_sql, :postgrex] do
      assert {:ok, _} = Application.ensure_all_started(app)
    end

    Application.load(:comms_core)

    # A dynamic Repo PID alone is insufficient: the retained central SQL
    # counter/preflight helpers resolve the named Core Repo. Start exactly that
    # Repo here, and prove both generated and static SQL read the same own DB.
    application_name =
      "k_comms/one_shot/history/" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

    config =
      Repo.config()
      |> Keyword.put(:url, url)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:parameters, application_name: application_name)

    assert {:ok, pid} = Repo.start_link(config)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert %{rows: [[^expected_database]]} = Repo.query!("SELECT current_database()", [])

    assert %{rows: [[^expected_database]]} =
             Ecto.Adapters.SQL.query!(Repo, "SELECT current_database()", [])

    assert [[^application_name, _, _, 0]] = Repo.release_migration_preflight!()
    assert %{rows: [[75]]} = Repo.query!("SELECT count(*) FROM schema_migrations", [])

    assert %{rows: [[20_261_006_001_300]]} =
             Repo.query!("SELECT max(version) FROM schema_migrations", [])

    assert %{rows: [["boolean", "NO", "false"]]} =
             Repo.query!(
               """
               SELECT data_type, is_nullable, column_default
               FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'conversation_memberships'
                 AND column_name = 'favorite'
               """,
               []
             )

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM oban_jobs", [])
    assert Audit.rollback_history_snapshot_hazard_count() == 0

    assert RuntimePorts.job_worker_name!(:audit_history_snapshot_purge) ==
             "CommsWorkers.AuditHistorySnapshotPurgeWorker"

    File.write!(
      receipt_path,
      Jason.encode!(
        %{
          database: expected_database,
          migration_count: 75,
          peers: 0,
          application_name: application_name,
          source_before: source_hashes(),
          beam_before: beam_hashes(),
          cases: []
        },
        pretty: true
      )
    )

    IO.puts("HISTORY canonical own database=" <> expected_database <> " migrations=75 peers=0")
    %{receipt_path: receipt_path}
  end

  for state <- @states,
      {label, args} <- [{"cron", %{}}, {"continuation", %{"continue" => true}}] do
    @state state
    @args args
    @label label
    test "actual canonical preflight refuses #{label} history job in #{state}", c do
      worker = RuntimePorts.job_worker_name!(:audit_history_snapshot_purge)
      id = raw_job!(worker, @state, @args)
      before = raw_snapshot([id])
      assert Audit.rollback_history_snapshot_hazard_count() == 0
      assert Repo.active_oban_job_count!(worker) == 1
      row = Repo.query!("SELECT state::text,args FROM oban_jobs WHERE id=$1", [id])
      assert row.rows == [[@state, @args]]

      try do
        # This invokes the actual private hazard collector through the public
        # entry, with actual PG quiescence and validated older capabilities.
        # The old continuation-only consumer must fail the five cron cases.
        assert_raise RuntimeError,
                     ~r/target e7d85225b875a83d071f10c27a5e3e7f2675540e lacks governance_history_v1.*active_history_purge_jobs=1/,
                     fn -> canonical_preflight(@m1_capabilities) end

        assert :ok = canonical_preflight(@m1_capabilities ++ ["governance_history_v1"])
        Process.put(:history_canonical_proof_complete, true)
      after
        after_snapshot = raw_snapshot([id])

        record_snapshot!(
          c.receipt_path,
          %{
            kind: @label,
            state: @state,
            args: @args,
            job_ids: [id],
            canonical_proof_complete: Process.get(:history_canonical_proof_complete, false)
          },
          before,
          after_snapshot
        )

        assert after_snapshot == before
      end
    end
  end

  test "terminal exact jobs and genuine foreign workers remain readable and permit canonical preflight",
       c do
    worker = RuntimePorts.job_worker_name!(:audit_history_snapshot_purge)

    terminal =
      for state <- @terminal_states, args <- [%{}, %{"continue" => true}] do
        raw_job!(worker, state, args)
      end

    foreign =
      for state <- @states,
          other <- ["CommsWorkers.NotificationDeliveryWorker", worker <> "Foreign"] do
        raw_job!(other, state, %{"continue" => true})
      end

    ids = terminal ++ foreign
    before = raw_snapshot(ids)
    assert Audit.rollback_history_snapshot_hazard_count() == 0
    assert Repo.active_oban_job_count!(worker) == 0

    try do
      assert :ok = canonical_preflight(@m1_capabilities)
      Process.put(:history_canonical_proof_complete, true)
    after
      after_snapshot = raw_snapshot(ids)

      record_snapshot!(
        c.receipt_path,
        %{
          kind: "terminal_foreign_controls",
          job_ids: ids,
          canonical_proof_complete: Process.get(:history_canonical_proof_complete, false)
        },
        before,
        after_snapshot
      )

      assert after_snapshot == before
    end
  end

  defp canonical_preflight(capabilities) do
    bindings = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_ROLLBACK_TARGET_REVISION" => "e7d85225b875a83d071f10c27a5e3e7f2675540e",
      "K_COMMS_ROLLBACK_TARGET_CAPABILITIES" => Enum.join(capabilities, ","),
      "K_COMMS_ROLLBACK_WRITES_QUIESCED" => "true"
    }

    previous = Map.new(Map.keys(bindings), &{&1, System.get_env(&1)})

    try do
      Enum.each(bindings, fn {key, value} -> System.put_env(key, value) end)
      Release.assert_communication_rollback_compatible!()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp raw_job!(worker, state, args) do
    assert %{rows: [[id]]} =
             Repo.query!(
               "INSERT INTO oban_jobs(worker,state,queue,args) VALUES ($1,$2::oban_job_state,'default',$3::jsonb) RETURNING id",
               [worker, state, args]
             )

    on_exit(fn -> Repo.query!("DELETE FROM oban_jobs WHERE id=$1", [id]) end)
    id
  end

  defp raw_snapshot(ids) do
    %{
      jobs: raw("SELECT * FROM oban_jobs WHERE id = ANY($1::bigint[]) ORDER BY id", [ids]),
      history_rows: raw("SELECT * FROM audit_resource_history_snapshots ORDER BY id", []),
      migration_versions: raw("SELECT * FROM schema_migrations ORDER BY version", []),
      schema_columns:
        raw(
          """
          SELECT table_name,column_name,data_type,udt_name,is_nullable,column_default
          FROM information_schema.columns WHERE table_schema=current_schema()
            AND table_name IN ('audit_events','audit_resource_history_snapshots','oban_jobs')
          ORDER BY table_name,ordinal_position
          """,
          []
        ),
      schema_indexes:
        raw(
          """
          SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname=current_schema()
            AND tablename IN ('audit_events','audit_resource_history_snapshots','oban_jobs')
          ORDER BY tablename,indexname
          """,
          []
        ),
      schema_constraints:
        raw(
          """
          SELECT t.relname,c.conname,c.contype,c.convalidated,pg_get_constraintdef(c.oid,true)
          FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
          JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname=current_schema()
            AND t.relname IN ('audit_events','audit_resource_history_snapshots','oban_jobs')
          ORDER BY t.relname,c.conname
          """,
          []
        )
    }
  end

  defp raw(sql, params) do
    result = Repo.query!(sql, params)
    Map.take(result, [:columns, :rows])
  end

  defp record_snapshot!(path, evidence, before, after_snapshot) do
    receipt = path |> File.read!() |> Jason.decode!()

    entry =
      Map.merge(evidence, %{
        before_sha256: snapshot_hashes(before),
        after_sha256: snapshot_hashes(after_snapshot),
        full_raw_snapshot_unchanged: before == after_snapshot
      })

    File.write!(
      path,
      Jason.encode!(Map.update!(receipt, "cases", &(&1 ++ [entry])), pretty: true)
    )
  end

  defp snapshot_hashes(snapshot),
    do: Map.new(snapshot, fn {key, value} -> {key, sha256(:erlang.term_to_binary(value))} end)

  defp source_hashes do
    for path <- [
          __ENV__.file,
          "apps/comms_core/lib/comms_core/repo.ex",
          "apps/comms_core/lib/comms_core/release/rollback_compatibility.ex",
          "apps/comms_core/lib/comms_core/release/migration.ex",
          "apps/comms_core/lib/comms_core/runtime_ports.ex",
          "apps/comms_core/priv/repo/migrations/20261006001300_add_conversation_favorites.exs",
          "apps/comms_workers/lib/comms_workers/audit_history_snapshot_purge_worker.ex",
          "config/config.exs"
        ],
        into: %{},
        do: {path, sha256(File.read!(path))}
  end

  defp beam_hashes do
    for module <- [Repo, CommsCore.Release.RollbackCompatibility], into: %{} do
      Code.ensure_loaded!(module)
      path = module |> :code.which() |> List.to_string()
      {inspect(module), %{path: path, sha256: sha256(File.read!(path))}}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

result = ExUnit.run()
receipt_path = System.fetch_env!("K_COMMS_HISTORY_PROBE_RECEIPT")

if File.exists?(receipt_path) do
  receipt = receipt_path |> File.read!() |> Jason.decode!()

  source_after =
    Map.new(receipt["source_before"], fn {path, _hash} ->
      {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
    end)

  beam_after =
    Map.new(receipt["beam_before"], fn {module, proof} ->
      {module,
       Map.put(
         proof,
         "sha256",
         :crypto.hash(:sha256, File.read!(proof["path"])) |> Base.encode16(case: :lower)
       )}
    end)

  receipt =
    receipt
    |> Map.put("result", result)
    |> Map.put("source_after", source_after)
    |> Map.put("beam_after", beam_after)
    |> Map.put("source_bytes_unchanged", source_after == receipt["source_before"])
    |> Map.put("beam_bytes_unchanged", beam_after == receipt["beam_before"])

  File.write!(receipt_path, Jason.encode!(receipt, pretty: true))
end

System.halt(if result.total == 11 and result.failures == 0, do: 0, else: 2)
