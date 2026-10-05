defmodule CommsCore.Accounts.RolePreviewAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, AdmissionQuotas, Repo}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "role-preview-current-authority-password-1234"

  test "preview waiting on the actual admission lock refuses an actor revoked before admission" do
    {account, target, subject} = fixture()
    parent = self()
    release = make_ref()

    blocker =
      actor(fn ->
        Repo.transaction(fn ->
          :ok = AdmissionQuotas.lock_tenant(account.tenant.id)
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:quota_retained, self(), backend})

          receive do
            {:release, ^release} -> :ok
          after
            10_000 -> raise "role preview quota barrier timed out"
          end
        end)
      end)

    assert_receive {:quota_retained, blocker_pid, blocker_backend}, 5_000

    preview =
      actor(fn ->
        [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
        send(parent, {:preview_backend, backend})

        Accounts.preview_user_role_change(
          target.id,
          %{role: :security_admin, version: target.lock_version},
          subject
        )
      end)

    assert_receive {:preview_backend, preview_backend}, 5_000
    {query, blockers} = wait_for_lock(preview_backend)
    assert String.contains?(query, "pg_advisory_xact_lock")
    assert blocker_backend in blockers

    # This public revoker can commit while the preview retains no identity rows.
    # Admission must derive authority again after the real preceding lock wait.
    assert :ok =
             unboxed(fn -> Accounts.revoke_own_session_command(account.session.id, subject) end)

    send(blocker_pid, {:release, release})
    assert {:ok, :ok} = Task.await(blocker, 10_000)
    assert {:error, :forbidden} = Task.await(preview, 10_000)

    unboxed(fn ->
      assert Repo.get!(Session, account.session.id).revoked_at
      current = Repo.get!(User, target.id)
      assert current.role == :member
      assert current.lock_version == target.lock_version
    end)
  end

  defp fixture do
    unboxed(fn ->
      suffix = Ecto.UUID.generate()

      account =
        Fixtures.account_fixture(%{
          tenant_slug: "role-preview-" <> suffix,
          email: "role-preview-#{suffix}@example.test",
          password: @password
        })

      tenant_id = account.tenant.id
      on_exit(fn -> cleanup(tenant_id) end)
      target = Fixtures.user_fixture(account).user
      subject = Fixtures.subject(account)
      assert {:ok, _} = Accounts.step_up(%{current_password: @password}, subject)
      {account, target, subject}
    end)
  end

  defp cleanup(tenant_id) do
    unboxed(fn ->
      Repo.transaction(fn ->
        event_ids =
          Repo.all(
            from(event in OutboxEvent, where: event.tenant_id == ^tenant_id, select: event.id)
          )

        Repo.delete_all(
          from(job in Oban.Job,
            where:
              fragment("?->>'tenant_id' = ?", job.args, ^tenant_id) or
                fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids)
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
      end)
    end)
  end

  defp actor(operation) do
    task = Task.async(fn -> unboxed(operation) end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp wait_for_lock(backend, attempts \\ 300)
  defp wait_for_lock(_backend, 0), do: flunk("preview did not reach an actual database lock wait")

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
