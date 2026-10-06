defmodule CommsCore.Accounts.SessionRevocationLockOrderTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Repo}
  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "revocation-lock-order-password-1234"

  for operation <- [:device, :own_session, :direct_session] do
    @operation operation

    test "#{operation} retains User before its lower row while a real authority request overlaps" do
      account = fixture()
      subject = Fixtures.subject(account)
      before_step_up = unboxed(fn -> Repo.get!(Session, account.session.id).step_up_at end)
      parent = self()

      revoker =
        actor(parent, :revoker, fn -> revoke(@operation, account, subject) end,
          barrier: &lower_lock?(&1, @operation)
        )

      assert_receive {:revoker_backend, revoker_backend}, 5_000
      assert_receive {:revoker_barrier, revoker_pid, release}, 5_000

      # Revocation is paused immediately after obtaining Device/Session UPDATE,
      # before effects or Audit have acquired any implicit User reference.
      authority =
        actor(parent, :authority, fn ->
          Accounts.step_up_view(%{current_password: @password}, subject)
        end)

      assert_receive {:authority_backend, authority_backend}, 5_000
      {query, blockers} = wait_for_lock(authority_backend, ~s(FROM "users"), revoker_backend)
      assert String.contains?(query, ~s(FROM "users"))
      assert revoker_backend in blockers

      send(revoker_pid, {:release_barrier, release})
      assert_success(@operation, Task.await(revoker, 10_000))
      assert {:error, :forbidden} = Task.await(authority, 10_000)

      unboxed(fn ->
        session = Repo.get!(Session, account.session.id)
        assert session.revoked_at
        assert session.step_up_at == before_step_up
        if @operation == :device, do: assert(Repo.get!(Device, account.device.id).revoked_at)
      end)
    end
  end

  for operation <- [:device, :own_session, :admin_session] do
    @operation operation

    test "#{operation} overlaps a Tenant UPDATE writer without an Audit User FK deadlock" do
      account = fixture()
      subject = Fixtures.subject(account)
      parent = self()

      settings =
        actor(
          parent,
          :settings,
          fn ->
            # Retain the stronger parent-row mode in an actual outer owner
            # transaction. This independently exercises User/Audit FK safety
            # even when the normal settings command uses NO KEY UPDATE.
            Repo.transaction(fn ->
              Repo.one!(
                from(tenant in Tenant,
                  where: tenant.id == ^account.tenant.id,
                  lock: "FOR UPDATE"
                )
              )

              case Administration.update_tenant_settings(
                     %{version: 1, name: "Concurrent tenant settings"},
                     subject
                   ) do
                {:ok, result} -> result
                {:error, reason} -> Repo.rollback(reason)
              end
            end)
          end,
          barrier: fn query ->
            String.contains?(query, ~s(FROM "tenants")) and
              String.contains?(query, "FOR UPDATE")
          end
        )

      assert_receive {:settings_backend, settings_backend}, 5_000
      assert_receive {:settings_barrier, settings_pid, settings_release}, 5_000

      revoker =
        actor(parent, :revoker, fn -> revoke(@operation, account, subject) end,
          barrier: &lower_lock?(&1, @operation)
        )

      assert_receive {:revoker_backend, revoker_backend}, 5_000
      assert_receive {:revoker_barrier, revoker_pid, revoker_release}, 5_000
      send(revoker_pid, {:release_barrier, revoker_release})

      # Audit now waits for the retained Tenant. The settings writer must still
      # acquire its actor User KEY SHARE and commit, despite revocation's User
      # fence. FOR UPDATE on that User would create a genuine wait cycle.
      {query, blockers} =
        wait_for_lock(revoker_backend, ~s(INSERT INTO "audit_events"), settings_backend)

      assert String.contains?(query, ~s(INSERT INTO "audit_events"))
      assert settings_backend in blockers
      send(settings_pid, {:release_barrier, settings_release})

      assert {:ok, result} = Task.await(settings, 10_000)
      assert result.tenant.name == "Concurrent tenant settings"
      assert_success(@operation, Task.await(revoker, 10_000))

      unboxed(fn ->
        assert Repo.get!(Session, account.session.id).revoked_at
        assert Repo.get!(Tenant, account.tenant.id).name == "Concurrent tenant settings"
      end)
    end
  end

  test "crossed administrator revocations lock the same sorted Users before Sessions" do
    account = fixture()
    second = additional_account(account, :owner)

    parent = self()

    first =
      actor(
        parent,
        :first,
        fn ->
          Accounts.admin_revoke_session_command(
            second.user.id,
            second.session.id,
            %{reason: "Crossed revocation first"},
            Fixtures.subject(account)
          )
        end,
        barrier: &lower_lock?(&1, :admin_session)
      )

    assert_receive {:first_backend, first_backend}, 5_000
    assert_receive {:first_barrier, first_pid, release}, 5_000

    crossed =
      actor(parent, :crossed, fn ->
        Accounts.admin_revoke_session_command(
          account.user.id,
          account.session.id,
          %{reason: "Crossed revocation second"},
          Fixtures.subject(second)
        )
      end)

    assert_receive {:crossed_backend, crossed_backend}, 5_000
    {query, blockers} = wait_for_lock(crossed_backend, ~s(FROM "users"), first_backend)
    assert String.contains?(query, ~s(FROM "users"))
    assert String.contains?(query, ~s(ORDER BY u0."id"))
    assert String.contains?(query, "FOR NO KEY UPDATE")
    assert first_backend in blockers
    send(first_pid, {:release_barrier, release})

    assert :ok = Task.await(first, 10_000)
    assert {:error, :forbidden} = Task.await(crossed, 10_000)

    unboxed(fn ->
      assert Repo.get!(Session, second.session.id).revoked_at
      refute Repo.get!(Session, account.session.id).revoked_at
    end)
  end

  test "administrator authority expiring during a real target Session lock wait has no revocation effect" do
    account = fixture()
    target = additional_account(account, :member)
    parent = self()

    holder =
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(session in Session,
              where: session.id == ^target.session.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, {:target_session_retained, self()})

          receive do
            :release_target -> :ok
          after
            10_000 -> raise "target Session holder timed out"
          end
        end)
      end)

    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive {:target_session_retained, holder_pid}, 5_000

    expires_at =
      unboxed(fn ->
        expiry = DateTime.add(DateTime.utc_now(), 3, :second)

        {1, _} =
          Repo.update_all(from(session in Session, where: session.id == ^account.session.id),
            set: [expires_at: expiry]
          )

        expiry
      end)

    revoker =
      actor(parent, :revoker, fn ->
        Accounts.admin_revoke_session_command(
          target.user.id,
          target.session.id,
          %{reason: "Must retain current administrator authority"},
          Fixtures.subject(account)
        )
      end)

    assert_receive {:revoker_backend, revoker_backend}, 5_000
    {query, blockers} = wait_for_lock(revoker_backend, ~s(FROM "sessions"), holder_backend)
    assert String.contains?(query, ~s(FROM "sessions"))
    assert holder_backend in blockers
    wait_for_expiry(expires_at)
    send(holder_pid, :release_target)

    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:error, :forbidden} = Task.await(revoker, 5_000)

    unboxed(fn ->
      refute Repo.get!(Session, target.session.id).revoked_at

      assert 0 ==
               CommsCore.Audit.count(%{
                 tenant_id: account.tenant.id,
                 action: "session.admin_revoke"
               })
    end)
  end

  for status <- [:suspended, :deleted] do
    @status status

    test "#{status} owners retain idempotent device and session cleanup" do
      for operation <- [:device, :own_session, :direct_session] do
        account = fixture()
        subject = Fixtures.subject(account)

        unboxed(fn ->
          {1, _} =
            Repo.update_all(from(user in User, where: user.id == ^account.user.id),
              set: [status: @status]
            )

          assert_success(operation, revoke(operation, account, subject))
          assert_success(operation, revoke(operation, account, subject))
          assert Repo.get!(Session, account.session.id).revoked_at
          if operation == :device, do: assert(Repo.get!(Device, account.device.id).revoked_at)
        end)
      end
    end
  end

  defp fixture do
    account =
      unboxed(fn ->
        account = Fixtures.account_fixture(%{password: @password})

        {:ok, _} =
          Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(account))

        account
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
      end)
    end)

    account
  end

  defp additional_account(account, role) do
    unboxed(fn ->
      %{user: user} =
        Fixtures.user_fixture(account, %{
          role: role,
          password_hash: CommsCore.Security.Password.hash(@password)
        })

      {:ok, login} = Accounts.authenticate_view(account.tenant.slug, user.email, @password, %{})
      session = Repo.get!(Session, login.session_id)

      result = %{
        tenant: account.tenant,
        user: user,
        device:
          Repo.get_by!(Device, id: session.device_id, user_id: user.id, tenant_id: user.tenant_id),
        session: session
      }

      {:ok, _} = Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(result))
      result
    end)
  end

  defp revoke(:device, account, subject),
    do: Accounts.revoke_device_command(account.device.id, subject)

  defp revoke(:own_session, account, subject),
    do: Accounts.revoke_own_session_command(account.session.id, subject)

  defp revoke(:direct_session, account, _subject),
    do: Accounts.revoke_session(account.session.id, account.user.id)

  defp revoke(:admin_session, account, subject),
    do:
      Accounts.admin_revoke_session_command(
        account.user.id,
        account.session.id,
        %{reason: "Concurrent owner cleanup"},
        subject
      )

  defp assert_success(:device, result), do: assert(match?({:ok, _}, result))
  defp assert_success(_, result), do: assert(result == :ok)

  defp lower_lock?(query, operation) do
    table = if operation == :device, do: ~s(FROM "devices"), else: ~s(FROM "sessions")
    String.contains?(query, table) and String.contains?(query, "FOR UPDATE")
  end

  defp actor(parent, label, operation, opts \\ []) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          if matcher = Keyword.get(opts, :barrier), do: attach_barrier(parent, label, matcher)
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp attach_barrier(parent, label, matcher) do
    handler = {__MODULE__, make_ref()}
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
              12_000 -> raise "revocation lock-order query barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend, expected_sql, expected_blocker, attempts \\ 300)

  defp wait_for_lock(_backend, expected_sql, _expected_blocker, 0),
    do: flunk("actor did not reach the expected database lock wait: #{expected_sql}")

  defp wait_for_lock(backend, expected_sql, expected_blocker, attempts) do
    observation =
      unboxed(fn ->
        Repo.query!(
          "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
          [backend]
        ).rows
      end)

    # PostgreSQL samples activity text before reading live wait/blocker state.
    # A transition into the row lock can still report the preceding set_config
    # query, so wait for the expected statement and its actual blocker together.
    # A wrong lock still exhausts the original bounded poll and fails.
    expected_wait? =
      case observation do
        [[query, blockers]] ->
          String.contains?(query, expected_sql) and expected_blocker in blockers

        [] ->
          false
      end

    if expected_wait? do
      [[query, blockers]] = observation
      {query, blockers}
    else
      Process.sleep(10)
      wait_for_lock(backend, expected_sql, expected_blocker, attempts - 1)
    end
  end

  defp wait_for_expiry(expires_at) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      Process.sleep(10)
      wait_for_expiry(expires_at)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
