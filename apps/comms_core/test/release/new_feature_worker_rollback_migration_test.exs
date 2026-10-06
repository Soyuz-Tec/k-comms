defmodule CommsCore.Release.NewFeatureWorkerRollbackMigrationTest.MigrationRepo do
  use Ecto.Repo, otp_app: :comms_core, adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.Release.NewFeatureWorkerRollbackMigrationTest do
  use ExUnit.Case, async: false

  alias CommsCore.{MigrationFixture, Repo}
  alias CommsCore.Release.NewFeatureWorkerRollbackMigrationTest.MigrationRepo, as: R
  alias Ecto.Adapters.SQL

  @moduletag :integration
  @moduletag :migration
  @parent_version 20_261_006_000_100
  @child_version 20_261_006_000_800
  @active_states ~w(available scheduled executing retryable suspended)
  @guards [
    %{
      label: "Calendar owner tables",
      version: 20_261_006_000_300,
      migration: CommsCore.Repo.Migrations.AddCalendarSync,
      workers: ~w(CommsWorkers.CalendarSyncWorker CommsWorkers.CalendarSyncReconcilerWorker),
      tables:
        ~w(calendar_connections calendar_oauth_challenges calendar_exports calendar_event_mappings calendar_sync_commands calendar_erasure_receipts),
      gone_tables:
        ~w(calendar_connections calendar_oauth_challenges calendar_exports calendar_event_mappings calendar_sync_commands calendar_erasure_receipts),
      gone_columns: [],
      queue: :lifecycle,
      refusal: ~r/calendar rollback blocked/
    },
    %{
      label: "Calendar export policy",
      version: 20_261_006_000_310,
      migration: CommsCore.Repo.Migrations.AddCalendarExportPolicy,
      workers: ~w(CommsWorkers.CalendarSyncWorker CommsWorkers.CalendarSyncReconcilerWorker),
      tables:
        ~w(tenant_settings calendar_connections calendar_oauth_challenges calendar_exports calendar_event_mappings calendar_sync_commands calendar_erasure_receipts),
      gone_tables: [],
      gone_columns: [
        {"tenant_settings", "allow_calendar_export"},
        {"tenant_settings", "calendar_export_policy_version"}
      ],
      queue: :lifecycle,
      refusal: ~r/calendar.*rollback blocked/
    },
    %{
      label: "bounded IVR and agent state",
      version: 20_261_006_000_400,
      migration: CommsCore.Repo.Migrations.AddBoundedIvrAndAgentState,
      workers: ~w(CommsWorkers.TelephonyIvrWorker),
      tables:
        ~w(telephony_ivr_menus telephony_ivr_runs telephony_ivr_event_receipts telephony_agent_states telephony_calls),
      gone_tables:
        ~w(telephony_ivr_menus telephony_ivr_runs telephony_ivr_event_receipts telephony_agent_states),
      gone_columns: [],
      queue: :lifecycle,
      refusal: ~r/IVR or agent state is retained/
    },
    %{
      label: "native call wake",
      version: 20_261_006_000_600,
      migration: CommsCore.Repo.Migrations.AddNativeCallWakeProtocol,
      workers: ~w(CommsWorkers.NativeCallWakeWorker CommsWorkers.NativePushReconcilerWorker),
      tables: ~w(native_push_registrations native_call_wakes),
      gone_tables: ~w(native_push_registrations native_call_wakes),
      gone_columns: [],
      queue: :notifications,
      refusal: ~r/native_call_wake_v1 retained state or active jobs/
    },
    %{
      label: "Recognition and summaries",
      version: 20_261_006_000_800,
      migration: CommsCore.Repo.Migrations.AddRecognitionSummaries,
      workers: ~w(CommsWorkers.CallSummaryWorker),
      tables: ~w(call_artifacts call_artifact_consents call_artifact_summaries),
      gone_tables: ~w(call_artifact_summaries),
      gone_columns:
        for(
          column <-
            ~w(summary_requested summary_source_sha256 summary_provider_claimed_at summary_claim_fingerprint summary_effect_started_at recognition_provider_id recognition_model_sha256 recognition_source_sha256),
          do: {"call_artifacts", column}
        ) ++
          for(
            column <- ~w(summary_accepted summary_policy_version summary_decided_at),
            do: {"call_artifact_consents", column}
          ),
      queue: :media,
      refusal: ~r/uc_recognition_summaries_v1 retained state or active jobs/
    }
  ]

  setup_all do
    base = Repo.config()
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    parent = "k_comms_direct_parent_" <> suffix
    database = "k_comms_direct_child_" <> suffix

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
      assert [[0]] =
               Postgrex.query!(admin, "SELECT count(*) FROM pg_database WHERE datname = $1", [
                 parent
               ]).rows

      assert :ok = Ecto.Adapters.Postgres.storage_up(Keyword.put(storage, :database, parent))

      # Use the actual immutable 62-migration parent, including concurrent-index
      # owner helpers. No parent schema, enum or foreign Ecto model is invented.
      uri = %URI{
        scheme: "ecto",
        host: Keyword.get(base, :hostname, "localhost"),
        port: Keyword.get(base, :port, 5432),
        userinfo:
          URI.encode(Keyword.fetch!(base, :username), &URI.char_unreserved?/1) <>
            ":" <> URI.encode(Keyword.fetch!(base, :password), &URI.char_unreserved?/1),
        path: "/" <> parent
      }

      {log, status} =
        System.cmd("mix", ["ecto.migrate", "--to", Integer.to_string(@parent_version)],
          cd: Path.expand("../../../..", __DIR__),
          env: [
            {"DATABASE_URL", URI.to_string(uri)},
            {"MIX_ENV", "test"},
            {"ERL_FLAGS", "+S 1:1"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, "fresh actual parent migration failed: " <> log

      assert :ok = MigrationFixture.await_no_peers(admin, parent)

      assert [[0]] =
               Postgrex.query!(
                 admin,
                 "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
                 [parent]
               ).rows

      assert [[0]] =
               Postgrex.query!(admin, "SELECT count(*) FROM pg_database WHERE datname = $1", [
                 database
               ]).rows

      assert :ok =
               Ecto.Adapters.Postgres.storage_up(
                 storage
                 |> Keyword.put(:database, database)
                 |> Keyword.put(:template, parent)
               )

      IO.puts(
        "Direct-down retained databases: parent=#{parent} child=#{database}; both_absence_count=0; protected_parent=20261006000100"
      )
    after
      GenServer.stop(admin)
    end

    config =
      storage
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:timeout, 15_000)
      |> Keyword.put(:parameters, statement_timeout: "15000", lock_timeout: "5000")
      |> Keyword.put(:migration_primary_key, Keyword.fetch!(base, :migration_primary_key))
      |> Keyword.put(:migration_foreign_key, Keyword.fetch!(base, :migration_foreign_key))

    assert {:ok, pid} = R.start_link(config)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    with_owned_repo(pid, database, fn ->
      assert length(Ecto.Migrator.migrated_versions(Repo)) == 62

      Ecto.Migrator.run(Repo, Application.app_dir(:comms_core, "priv/repo/migrations"), :up,
        to: @child_version,
        log: false
      )
    end)

    %{database: database, repo_pid: pid}
  end

  setup c do
    assert [[c.database]] == SQL.query!(R, "SELECT current_database()", []).rows
    assert raw_jobs().rows == []
    versions = migrated_versions(c)
    assert Enum.all?(@guards, &(&1.version in versions))
    assert Enum.all?(@guards, fn guard -> Enum.all?(raw_rows(guard).values, &(&1.rows == [])) end)
    :ok
  end

  for guard <- @guards do
    @guard guard
    test "empty #{@guard.label} direct down/up preserves the real parent", c do
      before_schema = schema_snapshot()
      before_versions = migrated_versions(c)
      assert :ok = down!(c, @guard)
      assert_removed(@guard)
      assert migrated_versions(c) == before_versions -- [@guard.version]
      assert :ok = up!(c, @guard)
      assert schema_snapshot() == before_schema
      assert migrated_versions(c) == before_versions
      assert Enum.all?(raw_rows(@guard).values, &(&1.rows == []))
    end

    for worker <- guard.workers, state <- @active_states do
      @guard guard
      @worker worker
      @state state
      @tag :orphan_feature_worker_rollback
      test "#{@guard.label} refuses orphan #{@worker} #{@state} before any DDL", c do
        before_schema = schema_snapshot()
        before_rows = raw_rows(@guard)
        before_versions = migrated_versions(c)
        before_version_rows = snapshot("SELECT * FROM schema_migrations ORDER BY version")
        job = insert_job!(c, @guard, @worker, @state)
        before_jobs = raw_jobs()

        try do
          assert_raise Postgrex.Error, @guard.refusal, fn -> down!(c, @guard) end
        after
          # Preserve the first real red outcome before exact-ID cleanup/reapply.
          IO.puts(
            "Direct-down orphan proof: version=#{@guard.version} worker=#{@worker} state=#{@state} job=#{job.id} version_retained=#{@guard.version in migrated_versions(c)} raw_job_unchanged=#{raw_jobs() == before_jobs} schema_unchanged=#{schema_snapshot() == before_schema}"
          )
        end

        assert migrated_versions(c) == before_versions
        assert snapshot("SELECT * FROM schema_migrations ORDER BY version") == before_version_rows
        assert schema_snapshot() == before_schema
        assert raw_rows(@guard) == before_rows
        assert raw_jobs() == before_jobs
      end
    end

    @guard guard
    test "#{@guard.label} allows terminal and exact foreign workers while preserving every job",
         c do
      before_schema = schema_snapshot()
      before_versions = migrated_versions(c)

      for worker <- @guard.workers,
          state <- ~w(completed cancelled discarded),
          do: insert_job!(c, @guard, worker, state)

      for state <- @active_states do
        insert_job!(c, @guard, "CommsWorkers.NotificationDeliveryWorker", state)
        for worker <- @guard.workers, do: insert_job!(c, @guard, worker <> "Unrelated", state)
      end

      # Existing capture/transcription and reconciler jobs stay compatible with
      # the legacy capability; summary/Recognition rows are guarded separately.
      if @guard.version == 20_261_006_000_800 do
        for worker <-
              ~w(CommsWorkers.CallArtifactWorker CommsWorkers.CallArtifactReconcilerWorker),
            state <- @active_states,
            do: insert_job!(c, @guard, worker, state)
      end

      before_jobs = raw_jobs()
      assert :ok = down!(c, @guard)
      assert_removed(@guard)
      assert migrated_versions(c) == before_versions -- [@guard.version]
      assert raw_jobs() == before_jobs
      assert :ok = up!(c, @guard)
      assert schema_snapshot() == before_schema
      assert migrated_versions(c) == before_versions
      assert raw_jobs() == before_jobs
      assert Enum.all?(raw_rows(@guard).values, &(&1.rows == []))
    end
  end

  defp insert_job!(c, guard, worker, state) do
    job =
      %{"orphan_id" => Ecto.UUID.generate(), "migration_fixture" => Ecto.UUID.generate()}
      |> Oban.Job.new(worker: worker, queue: guard.queue)
      |> Ecto.Changeset.put_change(:state, state)
      |> R.insert!()

    on_exit(fn ->
      if guard.version not in migrated_versions(c), do: assert(:ok == up!(c, guard))
      assert %{num_rows: 1} = SQL.query!(R, "DELETE FROM oban_jobs WHERE id = $1", [job.id])
    end)

    job
  end

  defp down!(c, guard),
    do:
      with_owned_repo(c.repo_pid, c.database, fn ->
        Ecto.Migrator.down(Repo, guard.version, guard.migration, log: false)
      end)

  defp up!(c, guard),
    do:
      with_owned_repo(c.repo_pid, c.database, fn ->
        Ecto.Migrator.up(Repo, guard.version, guard.migration, log: false)
      end)

  defp migrated_versions(c),
    do:
      with_owned_repo(c.repo_pid, c.database, fn ->
        Enum.sort(Ecto.Migrator.migrated_versions(Repo))
      end)

  defp with_owned_repo(pid, database, action) do
    previous = Repo.put_dynamic_repo(pid)

    try do
      assert [[^database]] = Repo.query!("SELECT current_database()", []).rows
      # Ecto.Migrator propagates this canonical dynamic Repo into its Runner
      # task, including the unchanged public Calendar00310 row/policy callback.
      action.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp assert_removed(guard) do
    for table <- guard.gone_tables do
      assert [[nil]] = SQL.query!(R, "SELECT to_regclass($1)", ["public." <> table]).rows
    end

    for {table, column} <- guard.gone_columns do
      assert [[0]] =
               SQL.query!(
                 R,
                 "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 AND column_name=$2",
                 [table, column]
               ).rows
    end
  end

  defp raw_jobs do
    snapshot("SELECT * FROM oban_jobs ORDER BY id")
  end

  defp raw_rows(guard) do
    %{
      tables: guard.tables,
      values: Enum.map(guard.tables, &snapshot("SELECT * FROM " <> &1 <> " ORDER BY id"))
    }
  end

  defp schema_snapshot do
    %{
      columns:
        snapshot(
          "SELECT table_name,column_name,data_type,udt_name,is_nullable,column_default,character_maximum_length,numeric_precision,numeric_scale,datetime_precision FROM information_schema.columns WHERE table_schema='public' ORDER BY table_name,column_name"
        ),
      constraints:
        snapshot(
          "SELECT c.relname,k.conname,k.contype,pg_get_constraintdef(k.oid,true),k.convalidated,k.condeferrable,k.condeferred FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' ORDER BY c.relname,k.conname"
        ),
      indexes:
        snapshot(
          "SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY tablename,indexname"
        ),
      triggers:
        snapshot(
          "SELECT c.relname,t.tgname,pg_get_triggerdef(t.oid,true),t.tgenabled FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal ORDER BY c.relname,t.tgname"
        )
    }
  end

  defp snapshot(sql) do
    result = SQL.query!(R, sql, [])
    %{columns: result.columns, rows: result.rows}
  end
end
