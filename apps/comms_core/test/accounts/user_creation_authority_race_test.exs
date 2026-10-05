defmodule CommsCore.Accounts.UserCreationAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, AdmissionQuotas, Audit, Repo}
  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "user-creation-authority-fixture-password-1234"

  for revocation <- [:session, :device] do
    @revocation revocation

    test "user creation refuses committed #{revocation} revocation during a real admission lock wait" do
      fixture = fixture()
      parent = self()
      {holder, holder_pid, holder_backend} = hold_admission(parent, fixture)

      creator = actor(parent, :creator, fn -> create(fixture) end)
      assert_receive {:creator_backend, creator_backend}, 5_000
      assert_admission_wait(creator_backend, holder_backend)

      # This is the actual public owner revocation on another connection. The
      # admission holder owns no User/Device/Session row that could hide it.
      result = unboxed(fn -> revoke(@revocation, fixture) end)
      assert_revoked(@revocation, result)
      send(holder_pid, :release_admission)

      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {:error, :forbidden} = Task.await(creator, 5_000)
      assert_no_creation(fixture)

      unboxed(fn ->
        assert Repo.get!(Session, fixture.account.session.id).revoked_at

        if @revocation == :device,
          do: assert(Repo.get!(Device, fixture.account.device.id).revoked_at)
      end)
    end
  end

  for authority <- [:session_expiry, :step_up_expiry] do
    @authority authority

    test "user creation refuses #{authority} reached during a real admission lock wait" do
      fixture = fixture()
      parent = self()
      {holder, holder_pid, holder_backend} = hold_admission(parent, fixture)
      expires_at = shorten_authority(@authority, fixture)

      # Prove that initial policy allows creation; only the subsequent real
      # lock wait crosses the persisted proof deadline.
      assert :ok =
               unboxed(fn ->
                 Accounts.authorize_manage_user_lifecycle(Fixtures.subject(fixture.account))
               end)

      creator = actor(parent, :creator, fn -> create(fixture) end)
      assert_receive {:creator_backend, creator_backend}, 5_000
      assert_admission_wait(creator_backend, holder_backend)
      wait_for_expiry(expires_at)
      send(holder_pid, :release_admission)

      assert {:ok, :ok} = Task.await(holder, 5_000)
      expected = if @authority == :step_up_expiry, do: :step_up_required, else: :forbidden
      assert {:error, ^expected} = Task.await(creator, 5_000)
      assert_no_creation(fixture)
    end
  end

  test "current owner creation succeeds once after the admission lock is released" do
    fixture = fixture()
    parent = self()
    {holder, holder_pid, holder_backend} = hold_admission(parent, fixture)

    creator = actor(parent, :creator, fn -> create(fixture) end)
    assert_receive {:creator_backend, creator_backend}, 5_000
    assert_admission_wait(creator_backend, holder_backend)
    send(holder_pid, :release_admission)

    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, created} = Task.await(creator, 5_000)
    assert created.role == :moderator
    assert created.email == fixture.email

    unboxed(fn ->
      users = Repo.all(from(user in User, where: user.tenant_id == ^fixture.account.tenant.id))
      assert Enum.count(users, &(&1.email == fixture.email)) == 1
      assert user_creation_audit_count(fixture.account.tenant.id) == fixture.audit_count + 1
      refute Repo.get!(Session, fixture.account.session.id).revoked_at
      refute Repo.get!(Device, fixture.account.device.id).revoked_at
    end)
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        account = Fixtures.account_fixture(%{password: @password})

        assert {:ok, _} =
                 Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(account))

        # Retrieve exact owner persistence structs rather than mutating adapter
        # authentication DTOs in the expiry fixtures.
        session = Repo.get!(Session, account.session.id)

        device =
          Repo.get_by!(Device,
            id: session.device_id,
            user_id: account.user.id,
            tenant_id: account.tenant.id
          )

        %{
          account: account,
          session: session,
          device: device,
          email: "create-race-#{account.user.id}@example.test",
          audit_count: user_creation_audit_count(account.tenant.id)
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^fixture.account.tenant.id)
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^fixture.account.tenant.id))
      end)
    end)

    fixture
  end

  defp create(fixture) do
    Accounts.create_user(
      %{
        display_name: "Creation authority race member",
        email: fixture.email,
        password: @password,
        role: "moderator"
      },
      Fixtures.subject(fixture.account)
    )
  end

  defp hold_admission(parent, fixture) do
    holder =
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          assert :ok = AdmissionQuotas.lock_tenant(fixture.account.tenant.id)
          send(parent, {:admission_retained, self()})

          receive do
            :release_admission -> :ok
          after
            12_000 -> raise "admission owner-lock holder timed out"
          end
        end)
      end)

    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive {:admission_retained, holder_pid}, 5_000
    {holder, holder_pid, holder_backend}
  end

  defp revoke(:session, fixture),
    do:
      Accounts.revoke_own_session_command(
        fixture.account.session.id,
        Fixtures.subject(fixture.account)
      )

  defp revoke(:device, fixture),
    do:
      Accounts.revoke_device_command(
        fixture.account.device.id,
        Fixtures.subject(fixture.account)
      )

  defp assert_revoked(:session, result), do: assert(result == :ok)
  defp assert_revoked(:device, result), do: assert(match?({:ok, _}, result))

  defp assert_no_creation(fixture) do
    unboxed(fn ->
      refute Repo.get_by(User, tenant_id: fixture.account.tenant.id, email: fixture.email)
      assert user_creation_audit_count(fixture.account.tenant.id) == fixture.audit_count
    end)
  end

  defp user_creation_audit_count(tenant_id),
    do: Audit.count(%{tenant_id: tenant_id, action: "user.create"})

  defp shorten_authority(:session_expiry, fixture) do
    unboxed(fn ->
      expires_at = DateTime.add(DateTime.utc_now(), 3, :second)
      session = Repo.get!(Session, fixture.session.id)
      Repo.update!(Ecto.Changeset.change(session, expires_at: expires_at))
      expires_at
    end)
  end

  defp shorten_authority(:step_up_expiry, fixture) do
    unboxed(fn ->
      ttl = Application.get_env(:comms_core, :step_up_ttl_seconds, 300)
      assert is_integer(ttl) and ttl >= 3
      step_up_at = DateTime.add(DateTime.utc_now(), 3 - ttl, :second)
      session = Repo.get!(Session, fixture.session.id)
      Repo.update!(Ecto.Changeset.change(session, step_up_at: step_up_at))
      DateTime.add(step_up_at, ttl, :second)
    end)
  end

  defp actor(parent, label, operation) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp assert_admission_wait(backend, blocker),
    do: assert_admission_wait(backend, blocker, System.monotonic_time(:millisecond) + 5_000)

  defp assert_admission_wait(backend, blocker, deadline) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
             [backend]
           ).rows
         end) do
      [[query, blockers]] ->
        assert String.contains?(query, "pg_advisory_xact_lock")
        assert blocker in blockers

      [] ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("creator did not reach the actual tenant-admission owner lock wait"),
          else:
            (
              Process.sleep(10)
              assert_admission_wait(backend, blocker, deadline)
            )
    end
  end

  defp wait_for_expiry(expires_at),
    do: wait_for_expiry(expires_at, System.monotonic_time(:millisecond) + 8_000)

  defp wait_for_expiry(expires_at, deadline) do
    if DateTime.compare(DateTime.utc_now(), expires_at) != :gt do
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("persisted creation authority did not expire within the bounded test wait"),
        else:
          (
            Process.sleep(10)
            wait_for_expiry(expires_at, deadline)
          )
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
