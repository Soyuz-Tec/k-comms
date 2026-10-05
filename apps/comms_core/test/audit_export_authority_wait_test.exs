defmodule CommsCore.AuditExportAuthorityWaitTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias CommsCore.{Accounts, Audit, AuditExport, Repo}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Administration.{IdentityAccessPort, IdentityGrant, Tenant}
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  setup do
    account = unboxed(fn -> Fixtures.account_fixture() end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          tenant_id = account.tenant.id

          event_ids =
            Repo.all(
              from(event in OutboxEvent, where: event.tenant_id == ^tenant_id, select: event.id)
            )

          Repo.delete_all(
            from(job in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^tenant_id) or
                  fragment("?->>'event_id'", job.args) in ^event_ids
            )
          )

          Repo.delete!(Repo.get!(Tenant, tenant_id))
        end)
      end)
    end)

    subject = unboxed(fn -> Fixtures.step_up(account) end)
    %{account: account, subject: subject}
  end

  test "independent resolution remains valid but disclosure locking requires a transaction",
       ctx do
    unboxed(fn ->
      assert {:ok, %IdentityGrant{role: :owner, step_up_recent?: true}} =
               IdentityAccessPort.resolve_access(ctx.subject)

      assert {:error, :transaction_required} =
               IdentityAccessPort.lock_access(ctx.subject, deadline())
    end)
  end

  test "a valid second session cannot replace the initiating session revoked during owner wait",
       ctx do
    second =
      unboxed(fn ->
        suffix = ctx.account.tenant.slug |> String.split("-") |> List.last()

        {:ok, authentication} =
          Accounts.authenticate_view(
            ctx.account.tenant.slug,
            ctx.account.user.email,
            "correct-horse-battery-#{suffix}",
            %{name: "Independent second browser", platform: "test"}
          )

        {:ok, %{subject: subject}} = Accounts.access_context(authentication.session_id)
        Fixtures.step_up(ctx.account, subject)
      end)

    {holder, reader} = wait_at_tenant(ctx)

    assert :ok =
             unboxed(fn ->
               Accounts.revoke_session(ctx.account.session.id, ctx.account.user.id)
             end)

    assert {:ok, %IdentityGrant{step_up_recent?: true}} =
             unboxed(fn -> IdentityAccessPort.resolve_access(second) end)

    release(holder)
    assert {:error, :forbidden} = Task.await(reader, 10_000)
    assert_no_export(ctx)
  end

  test "an expired caller deadline cannot be replaced by a fresh owner budget", ctx do
    assert {:error, :forbidden} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 IdentityAccessPort.lock_access(
                   ctx.subject,
                   System.monotonic_time(:millisecond) - 1
                 )
               end)
             end)

    assert_no_export(ctx)
  end

  for withdrawal <- [:role, :access_scope] do
    @withdrawal withdrawal
    test "persisted #{@withdrawal} withdrawal during owner wait refuses CSV despite stale subject",
         ctx do
      {holder, reader} = wait_at_tenant(ctx)

      unboxed(fn ->
        changes =
          case @withdrawal do
            :role -> [role: :member]
            :access_scope -> [access_scope: :conversation_only]
          end

        Repo.get!(User, ctx.account.user.id)
        |> Ecto.Changeset.change(changes)
        |> Repo.update!()
      end)

      release(holder)
      assert {:error, :forbidden} = Task.await(reader, 10_000)
      assert_no_export(ctx)
    end
  end

  for expiry <- [:session, :step_up] do
    @expiry expiry
    test "#{@expiry} expiry during the actual read-audit INSERT wait prevents final plaintext disclosure",
         ctx do
      expires_at = DateTime.add(DateTime.utc_now(), 3, :second)

      unboxed(fn ->
        changes =
          case @expiry do
            :session -> [expires_at: expires_at]
            :step_up -> [step_up_at: DateTime.add(expires_at, -300, :second)]
          end

        Repo.get!(Session, ctx.account.session.id)
        |> Ecto.Changeset.change(changes)
        |> Repo.update!()
      end)

      holder = hold(fn -> Repo.query!("LOCK TABLE audit_events IN SHARE MODE", []) end)
      assert_receive {:held, holder_pid, holder_backend}, 5_000
      reader = run(fn -> AuditExport.export(%{}, ctx.subject) end)
      assert_receive {:reader_backend, reader_backend}, 5_000
      {query, blockers} = wait_for_lock(reader_backend)
      assert query =~ ~s(INSERT INTO "audit_events")
      assert holder_backend in blockers
      await_expiry(expires_at)
      send(holder_pid, :release)
      assert {:ok, :held} = Task.await(holder, 10_000)
      expected = if @expiry == :session, do: :forbidden, else: :step_up_required
      assert {:error, ^expected} = Task.await(reader, 10_000)
      assert_no_export(ctx)
    end
  end

  defp wait_at_tenant(ctx) do
    holder =
      hold(fn ->
        Repo.one!(
          from(tenant in Tenant, where: tenant.id == ^ctx.account.tenant.id, lock: "FOR UPDATE")
        )
      end)

    assert_receive {:held, _holder_pid, holder_backend}, 5_000
    reader = run(fn -> AuditExport.export(%{}, ctx.subject) end)
    assert_receive {:reader_backend, reader_backend}, 5_000
    {query, blockers} = wait_for_lock(reader_backend)
    assert query =~ ~s(FROM "tenants")
    assert query =~ "FOR SHARE"
    assert holder_backend in blockers
    {holder, reader}
  end

  defp assert_no_export(ctx) do
    assert unboxed(fn ->
             Audit.count(%{tenant_id: ctx.account.tenant.id, action: "audit.export"})
           end) == 0
  end

  defp hold(operation) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            operation.()
            [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:held, self(), backend})

            receive do
              :release -> :held
            after
              12_000 -> raise "audit export holder timed out"
            end
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp release(holder) do
    send(holder.pid, :release)
    assert {:ok, :held} = Task.await(holder, 10_000)
  end

  defp run(operation) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:reader_backend, backend})
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp wait_for_lock(backend, attempts \\ 300)
  defp wait_for_lock(_backend, 0), do: flunk("export did not reach a real PostgreSQL lock wait")

  defp wait_for_lock(backend, attempts) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
             [backend]
           ).rows
         end) do
      [[query, blockers]] ->
        {query, blockers}

      [] ->
        Process.sleep(10)
        wait_for_lock(backend, attempts - 1)
    end
  end

  defp await_expiry(expires_at) do
    remaining = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    if remaining > 0, do: Process.sleep(remaining + 30)
    assert DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 15_000
  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
