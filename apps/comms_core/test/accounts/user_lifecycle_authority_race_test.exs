defmodule CommsCore.Accounts.UserLifecycleAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Audit, Governance, Repo}
  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "user-lifecycle-authority-fixture-password-1234"

  for entry <- [:direct, :governed], revocation <- [:session, :device] do
    @entry entry
    @revocation revocation

    test "#{entry} lifecycle refuses #{revocation} revocation committed during its real User lock wait" do
      fixture = fixture()
      before = snapshot(fixture)
      parent = self()

      revoker =
        actor(parent, :revoker, fn -> revoke(@revocation, fixture) end,
          barrier: &lower_lock?(&1, @revocation)
        )

      assert_receive {:revoker_backend, revoker_backend}, 5_000
      assert_receive {:revoker_barrier, revoker_pid, release}, 5_000

      # The revoker already owns User and Device/Session locks but its mutation
      # is uncommitted. Plain preflight reads still see the prior active grant.
      lifecycle = actor(parent, :lifecycle, fn -> change(@entry, fixture) end)
      assert_receive {:lifecycle_backend, lifecycle_backend}, 5_000
      {query, blockers} = wait_for_lock(lifecycle_backend)
      assert String.contains?(query, ~s(FROM "users"))
      assert revoker_backend in blockers

      send(revoker_pid, {:release_barrier, release})
      assert_revoked(@revocation, Task.await(revoker, 10_000))
      assert {:error, :forbidden} = Task.await(lifecycle, 10_000)
      assert snapshot(fixture) == before

      unboxed(fn ->
        assert Repo.get!(Session, fixture.account.session.id).revoked_at

        if @revocation == :device,
          do: assert(Repo.get!(Device, fixture.account.device.id).revoked_at)
      end)
    end
  end

  for entry <- [:direct, :governed], authority <- [:session_expiry, :step_up_expiry] do
    @entry entry
    @authority authority

    test "#{entry} lifecycle refuses #{authority} reached during a real target User lock wait" do
      fixture = fixture()
      before = snapshot(fixture)
      parent = self()

      holder =
        actor(parent, :holder, fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(user in User,
                where: user.id == ^fixture.target.user.id,
                lock: "FOR UPDATE"
              )
            )

            send(parent, {:target_user_retained, self()})

            receive do
              :release_target -> :ok
            after
              12_000 -> raise "target User holder timed out"
            end
          end)
        end)

      assert_receive {:holder_backend, holder_backend}, 5_000
      assert_receive {:target_user_retained, holder_pid}, 5_000
      expires_at = shorten_authority(@authority, fixture)

      lifecycle = actor(parent, :lifecycle, fn -> change(@entry, fixture) end)
      assert_receive {:lifecycle_backend, lifecycle_backend}, 5_000
      {query, blockers} = wait_for_lock(lifecycle_backend)
      assert String.contains?(query, ~s(FROM "users"))
      assert holder_backend in blockers
      wait_for_expiry(expires_at)
      send(holder_pid, :release_target)

      assert {:ok, :ok} = Task.await(holder, 5_000)

      expected = if @authority == :step_up_expiry, do: :step_up_required, else: :forbidden
      assert {:error, ^expected} = Task.await(lifecycle, 5_000)
      assert snapshot(fixture) == before
    end
  end

  for entry <- [:direct, :governed] do
    @entry entry

    test "#{entry} lifecycle applies a role change exactly once while initiating authority remains current" do
      fixture = fixture()

      assert {:ok, result} = unboxed(fn -> change(@entry, fixture) end)
      assert result.user.role == :moderator
      assert result.revoked_session_ids == []

      unboxed(fn ->
        user = Repo.get!(User, fixture.target.user.id)
        assert user.role == :moderator
        assert user.lock_version == fixture.target.user.lock_version + 1
        assert lifecycle_audit_count(fixture.account.tenant.id, user.id) == 1
        refute Repo.get!(Session, fixture.target.session.id).revoked_at
        refute Repo.get!(Device, fixture.target.device.id).revoked_at
      end)
    end
  end

  test "a current owner may demote their own role when another effective owner remains" do
    fixture = fixture()
    account = fixture.account

    unboxed(fn -> Fixtures.user_fixture(account, %{role: :owner}) end)

    assert {:ok, result} =
             unboxed(fn ->
               Governance.change_user_lifecycle_view(
                 account.user.id,
                 %{
                   role: "member",
                   version: account.user.lock_version,
                   reason: "Hand over ownership and retain ordinary membership"
                 },
                 Fixtures.subject(account)
               )
             end)

    assert result.user.role == :member
    assert result.revoked_session_ids == []

    unboxed(fn ->
      assert Repo.get!(User, account.user.id).role == :member
      refute Repo.get!(Session, account.session.id).revoked_at
      assert {:error, :forbidden} = Accounts.authorize_administer_users(Fixtures.subject(account))
      assert lifecycle_audit_count(account.tenant.id, account.user.id) == 1
    end)
  end

  test "the final authority barrier preserves the last active owner invariant" do
    fixture = fixture()
    account = fixture.account

    assert {:error, :last_owner_required} =
             unboxed(fn ->
               Governance.change_user_lifecycle_view(
                 account.user.id,
                 %{
                   role: "member",
                   version: account.user.lock_version,
                   reason: "The final owner must be retained"
                 },
                 Fixtures.subject(account)
               )
             end)

    unboxed(fn ->
      user = Repo.get!(User, account.user.id)
      assert user.role == :owner
      assert user.lock_version == account.user.lock_version
      refute Repo.get!(Session, account.session.id).revoked_at
      assert lifecycle_audit_count(account.tenant.id, account.user.id) == 0
    end)
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        account = Fixtures.account_fixture(%{password: @password})

        assert {:ok, _} =
                 Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(account))

        %{user: user} =
          Fixtures.user_fixture(account, %{
            role: :member,
            password_hash: CommsCore.Security.Password.hash(@password)
          })

        assert {:ok, login} =
                 Accounts.password_sign_in(account.tenant.slug, user.email, @password, %{})

        # Adapter authentication contracts are not Ecto persistence structs.
        # Retrieve the exact persisted Session/Device before any fixture mutation.
        session = Repo.get!(Session, login.session_id)

        device =
          Repo.get_by!(Device,
            id: session.device_id,
            tenant_id: user.tenant_id,
            user_id: user.id
          )

        %{account: account, target: %{user: user, session: session, device: device}}
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

  defp change(entry, fixture) do
    attrs = %{
      role: "moderator",
      version: fixture.target.user.lock_version,
      reason: "Role change must retain the current initiating authority"
    }

    subject = Fixtures.subject(fixture.account)

    case entry do
      :direct -> Accounts.change_user_with_effects(fixture.target.user.id, attrs, subject)
      :governed -> Governance.change_user_lifecycle_view(fixture.target.user.id, attrs, subject)
    end
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

  defp snapshot(fixture) do
    unboxed(fn ->
      user = Repo.get!(User, fixture.target.user.id)
      session = Repo.get!(Session, fixture.target.session.id)
      device = Repo.get!(Device, fixture.target.device.id)

      %{
        role: user.role,
        status: user.status,
        version: user.lock_version,
        display_name: user.display_name,
        session_revoked_at: session.revoked_at,
        session_step_up_at: session.step_up_at,
        device_revoked_at: device.revoked_at,
        lifecycle_audit_count: lifecycle_audit_count(user.tenant_id, user.id)
      }
    end)
  end

  defp lifecycle_audit_count(tenant_id, user_id),
    do:
      Audit.count(%{
        tenant_id: tenant_id,
        resource_id: user_id,
        action: "user.lifecycle_update"
      })

  defp shorten_authority(:session_expiry, fixture) do
    unboxed(fn ->
      expires_at = DateTime.add(DateTime.utc_now(), 3, :second)
      session = Repo.get!(Session, fixture.account.session.id)
      Repo.update!(Ecto.Changeset.change(session, expires_at: expires_at))
      expires_at
    end)
  end

  defp shorten_authority(:step_up_expiry, fixture) do
    unboxed(fn ->
      ttl = Application.get_env(:comms_core, :step_up_ttl_seconds, 300)
      assert is_integer(ttl) and ttl >= 3
      # With the current 300-second TTL this is now minus 297 seconds: three
      # seconds of valid proof remain without changing application configuration.
      step_up_at = DateTime.add(DateTime.utc_now(), 3 - ttl, :second)
      session = Repo.get!(Session, fixture.account.session.id)
      Repo.update!(Ecto.Changeset.change(session, step_up_at: step_up_at))
      DateTime.add(step_up_at, ttl, :second)
    end)
  end

  defp lower_lock?(query, revocation) do
    table = if revocation == :device, do: ~s(FROM "devices"), else: ~s(FROM "sessions")
    String.contains?(query, table) and String.contains?(query, "FOR UPDATE")
  end

  defp actor(parent, label, operation, opts \\ []) do
    handler = {__MODULE__, make_ref()}

    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})

          if matcher = Keyword.get(opts, :barrier),
            do: attach_barrier(parent, label, matcher, handler)

          operation.()
        end)
      end)

    on_exit(fn ->
      :telemetry.detach(handler)
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    task
  end

  defp attach_barrier(parent, label, matcher, handler) do
    release = make_ref()
    actor = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == actor and matcher.(metadata.query) do
            :telemetry.detach(handler)
            send(parent, {String.to_atom("#{label}_barrier"), self(), release})

            receive do
              {:release_barrier, ^release} -> :ok
            after
              12_000 -> raise "lifecycle revocation query barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend),
    do: wait_for_lock(backend, System.monotonic_time(:millisecond) + 5_000)

  defp wait_for_lock(backend, deadline) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
             [backend]
           ).rows
         end) do
      [[query, blockers]] ->
        {query, blockers}

      [] ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("lifecycle did not reach an actual database User lock wait"),
          else:
            (
              Process.sleep(10)
              wait_for_lock(backend, deadline)
            )
    end
  end

  defp wait_for_expiry(expires_at),
    do: wait_for_expiry(expires_at, System.monotonic_time(:millisecond) + 8_000)

  defp wait_for_expiry(expires_at, deadline) do
    if DateTime.compare(DateTime.utc_now(), expires_at) != :gt do
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("persisted authority did not expire within the bounded test wait"),
        else:
          (
            Process.sleep(10)
            wait_for_expiry(expires_at, deadline)
          )
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
