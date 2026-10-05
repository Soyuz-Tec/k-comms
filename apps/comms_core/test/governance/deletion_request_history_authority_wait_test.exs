defmodule CommsCore.Governance.DeletionRequestHistoryAuthorityWaitTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Governance, Repo}
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Governance.{DeletionRequest, TenantLock}
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  @moduletag :integration
  @moduletag :concurrency
  @moduletag :governance

  setup do
    previous = Application.get_env(:comms_core, :governance_history_cursor_key)

    Application.put_env(
      :comms_core,
      :governance_history_cursor_key,
      "synthetic-history-wait-test-key-only"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :governance_history_cursor_key, previous),
        else: Application.delete_env(:comms_core, :governance_history_cursor_key)
    end)

    account = unboxed(fn -> Fixtures.account_fixture() end)
    # Register before later fixture work so a setup failure cannot leak jobs/rows.
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

    {subject, request} =
      unboxed(fn ->
        subject = Fixtures.step_up(account)
        target = Fixtures.user_fixture(account)

        {:ok, result} =
          Governance.create_deletion_request(
            %{
              target_type: "user",
              subject_user_id: target.user.id,
              reason: "Synthetic history authority overlap"
            },
            subject
          )

        {subject, result.request}
      end)

    %{account: account, subject: subject, request: request}
  end

  test "session revoked while timeline waits on the exact tenant fence prevents disclosure",
       ctx do
    holder = hold(fn -> TenantLock.lock!(ctx.account.tenant.id) end)
    assert_receive {:held, holder_pid, holder_backend}, 5_000
    reader = run(fn -> Governance.deletion_request_timeline(ctx.request.id, %{}, ctx.subject) end)
    assert_receive {:reader_backend, reader_backend}, 5_000
    {query, blockers} = wait_for_lock(reader_backend)
    assert query =~ "pg_advisory_xact_lock"
    assert holder_backend in blockers

    assert :ok =
             unboxed(fn ->
               Accounts.revoke_session(ctx.account.session.id, ctx.account.user.id)
             end)

    send(holder_pid, :release)
    assert {:ok, :held} = Task.await(holder, 10_000)
    assert {:error, :forbidden} = Task.await(reader, 10_000)

    assert unboxed(fn ->
             Repo.query!(
               "SELECT count(*) FROM audit_resource_history_snapshots WHERE tenant_id = $1::uuid",
               [Ecto.UUID.dump!(ctx.account.tenant.id)]
             ).rows
           end) == [[0]]
  end

  for boundary <- [:session_expiry, :step_up_expiry] do
    @boundary boundary
    test "CSV refuses #{@boundary} after a real exact Request row lock wait", ctx do
      holder =
        hold(fn ->
          Repo.one!(
            from(request in DeletionRequest,
              where: request.id == ^ctx.request.id,
              lock: "FOR UPDATE"
            )
          )
        end)

      assert_receive {:held, holder_pid, holder_backend}, 5_000

      unboxed(fn ->
        changes =
          case @boundary do
            :session_expiry -> [expires_at: DateTime.add(DateTime.utc_now(), 3, :second)]
            :step_up_expiry -> [step_up_at: DateTime.add(DateTime.utc_now(), -297, :second)]
          end

        Repo.get!(Session, ctx.account.session.id)
        |> Ecto.Changeset.change(changes)
        |> Repo.update!()
      end)

      reader =
        run(fn ->
          Governance.export_deletion_request_history(ctx.request.id, %{}, ctx.subject)
        end)

      assert_receive {:reader_backend, reader_backend}, 5_000
      {query, blockers} = wait_for_lock(reader_backend)
      assert query =~ ~s(FROM "deletion_requests")
      assert query =~ "FOR SHARE"
      assert holder_backend in blockers
      Process.sleep(3_200)
      send(holder_pid, :release)
      assert {:ok, :held} = Task.await(holder, 10_000)
      expected = if @boundary == :session_expiry, do: :forbidden, else: :step_up_required
      assert {:error, ^expected} = Task.await(reader, 10_000)

      assert unboxed(fn ->
               CommsCore.Audit.count(%{
                 tenant_id: ctx.account.tenant.id,
                 resource_id: ctx.request.id,
                 action: "deletion_request.history_export"
               })
             end) == 0

      assert unboxed(fn ->
               Repo.query!(
                 "SELECT count(*) FROM audit_resource_history_snapshots WHERE tenant_id = $1::uuid",
                 [Ecto.UUID.dump!(ctx.account.tenant.id)]
               ).rows
             end) == [[0]]
    end
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
              12_000 -> raise "history row holder timed out"
            end
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
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
  defp wait_for_lock(_backend, 0), do: flunk("history did not reach a real PostgreSQL lock wait")

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

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
