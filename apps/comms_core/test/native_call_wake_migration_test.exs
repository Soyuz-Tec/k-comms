defmodule CommsCore.NativeCallWakeMigrationTest.MigrationRepo do
  use Ecto.Repo, otp_app: :comms_core, adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.NativeCallWakeMigrationTest do
  use ExUnit.Case, async: false
  alias CommsCore.NativeCallWakeMigrationTest.MigrationRepo, as: Repo
  alias CommsCore.Repo.Migrations.AddNativeCallWakeProtocol, as: Migration
  alias Ecto.Adapters.SQL
  @version 20_261_006_000_600
  @moduletag :integration
  @moduletag :migration
  @workers ~w(CommsWorkers.NativeCallWakeWorker CommsWorkers.NativePushReconcilerWorker)

  setup do
    database = "k_comms_native_wake_" <> String.replace(Ecto.UUID.generate(), "-", "")
    base = CommsCore.Repo.config()
    storage = base |> Keyword.take([:hostname, :port, :username, :password]) |> Keyword.put(:database, database)
    config = storage |> Keyword.put(:pool, DBConnection.ConnectionPool) |> Keyword.put(:pool_size, 2)
    assert :ok = Ecto.Adapters.Postgres.storage_up(storage)
    assert {:ok, pid} = Repo.start_link(config)
    Process.unlink(pid)
    previous = Code.compiler_options(); Code.compiler_options(ignore_module_conflict: true)
    on_exit(fn ->
      Code.compiler_options(previous)
      if Process.alive?(pid), do: GenServer.stop(pid)
      assert :ok = Ecto.Adapters.Postgres.storage_down(storage)
    end)
    path = Application.app_dir(:comms_core, "priv/repo/migrations")
    Code.require_file(Path.join(path, "20260711000200_add_oban_jobs.exs"))
    assert :ok = Ecto.Migrator.up(Repo, 1, CommsCore.Repo.Migrations.AddObanJobs, log: false)
    for statement <- [
      "CREATE TABLE tenants (id uuid PRIMARY KEY)",
      "CREATE TABLE users (id uuid PRIMARY KEY, tenant_id uuid NOT NULL, UNIQUE(tenant_id,id))",
      "CREATE TABLE devices (id uuid PRIMARY KEY, tenant_id uuid NOT NULL, user_id uuid NOT NULL, UNIQUE(tenant_id,user_id,id))",
      "CREATE TABLE sessions (id uuid PRIMARY KEY, tenant_id uuid NOT NULL, UNIQUE(tenant_id,id))"
    ], do: SQL.query!(Repo, statement)
    Code.require_file(Path.join(path, "20261006000600_add_native_call_wake_protocol.exs"))
    assert :ok = Ecto.Migrator.up(Repo, @version, Migration, log: false)
    :ok
  end

  test "exact active worker jobs, including orphans, refuse before any native DDL" do
    for worker <- @workers, state <- ~w(available scheduled executing retryable) do
      SQL.query!(Repo, "INSERT INTO oban_jobs (worker,state,queue,args,max_attempts) VALUES ($1,$2,'notifications','{}',3)", [worker, state])
      refuse_down!()
      SQL.query!(Repo, "DELETE FROM oban_jobs")
    end
    # Similar names and terminal jobs cannot widen or permanently block the
    # exact active-job capability. The real Oban migration supplies its enum.
    for state <- ~w(completed discarded cancelled), worker <- @workers do
      SQL.query!(Repo, "INSERT INTO oban_jobs (worker,state,queue,args,max_attempts) VALUES ($1,$2,'notifications','{}',3)", [worker, state])
    end
    SQL.query!(Repo, "INSERT INTO oban_jobs (worker,queue,args,max_attempts) VALUES ('CommsWorkers.NativeCallWakeWorkerExtra','notifications','{}',3)")
    assert :ok = Ecto.Migrator.down(Repo, @version, Migration, log: false)
    assert [[nil, nil]] = SQL.query!(Repo, "SELECT to_regclass('native_push_registrations'),to_regclass('native_call_wakes')").rows
  end

  test "revoked fingerprints and consumed intents refuse rollback until verified owner erasure" do
    tenant = Ecto.UUID.generate(); user = Ecto.UUID.generate(); device = Ecto.UUID.generate(); session = Ecto.UUID.generate()
    registration = Ecto.UUID.generate(); intent = Ecto.UUID.generate()
    SQL.query!(Repo, "INSERT INTO tenants VALUES ($1::text::uuid)", [tenant])
    SQL.query!(Repo, "INSERT INTO users VALUES ($1::text::uuid,$2::text::uuid)", [user, tenant])
    SQL.query!(Repo, "INSERT INTO devices VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid)", [device, tenant, user])
    SQL.query!(Repo, "INSERT INTO sessions VALUES ($1::text::uuid,$2::text::uuid)", [session, tenant])
    SQL.query!(Repo, """
    INSERT INTO native_push_registrations
    (id,tenant_id,user_id,device_id,session_id,installation_id,user_version,platform,channel,application_id,environment,version,token_hash,status,expires_at,inserted_at,updated_at)
    VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5::text::uuid,$1::text::uuid,1,'ios','apns_voip','com.synthetic.native','sandbox',1,$6,'revoked',clock_timestamp(),clock_timestamp(),clock_timestamp())
    """, [registration, tenant, user, device, session, :crypto.strong_rand_bytes(32)])
    refuse_down!()
    SQL.query!(Repo, """
    INSERT INTO native_call_wakes
    (id,tenant_id,user_id,device_id,session_id,registration_id,registration_version,user_version,owner,call_id,conversation_id,source_event_id,status,expires_at,inserted_at,updated_at)
    VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5::text::uuid,$6::text::uuid,1,1,'conversation',$1::text::uuid,$1::text::uuid,$1::text::uuid,'consumed',clock_timestamp(),clock_timestamp(),clock_timestamp())
    """, [intent, tenant, user, device, session, registration])
    refuse_down!()
    assert_raise Postgrex.Error, fn -> SQL.query!(Repo, "DELETE FROM sessions WHERE id=$1::text::uuid", [session]) end
    assert [[1]] = SQL.query!(Repo, "SELECT count(*) FROM native_push_registrations").rows
    SQL.query!(Repo, "DELETE FROM native_push_registrations")
    assert [[0]] = SQL.query!(Repo, "SELECT count(*) FROM native_call_wakes").rows
    SQL.query!(Repo, "DELETE FROM sessions WHERE id=$1::text::uuid", [session])
    assert [[0]] = SQL.query!(Repo, "SELECT count(*) FROM sessions").rows
    assert :ok = Ecto.Migrator.down(Repo, @version, Migration, log: false)
  end

  defp refuse_down! do
    assert_raise Postgrex.Error, ~r/native_call_wake_v1 retained state or active jobs/, fn ->
      Ecto.Migrator.down(Repo, @version, Migration, log: false)
    end
    assert [[true, true]] = SQL.query!(Repo,
      "SELECT to_regclass('native_push_registrations') IS NOT NULL,to_regclass('native_call_wakes') IS NOT NULL").rows
  end
end
