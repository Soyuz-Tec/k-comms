defmodule CommsCore.Accounts.CalendarAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{CalendarActorLockQuery, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  @moduletag :integration
  @moduletag :concurrency

  setup do
    account = unboxed(fn -> Fixtures.account_fixture() end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^account.tenant.id)) end)
    end)

    %{account: account, subject: Fixtures.subject(account)}
  end

  test "an interactive calendar actor waits for scope withdrawal and denies after the real commit",
       %{account: account, subject: subject} do
    parent = self()

    revoker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            identity =
              Repo.one!(
                from(u in User, where: u.id == ^account.user.id, lock: "FOR NO KEY UPDATE")
              )

            Repo.update!(Ecto.Changeset.change(identity, access_scope: :conversation_only))
            send(parent, {:withdrawal_staged, self(), backend_pid()})

            receive do
              :commit -> :ok
            after
              10_000 -> raise "calendar withdrawal barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:withdrawal_staged, revoker_pid, revoker_backend}, 5000

    actor =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            send(parent, {:calendar_backend, backend_pid()})

            case Accounts.lock_calendar_actor(%CalendarActorLockQuery{
                   subject: subject,
                   deadline_ms: deadline(),
                   require_step_up?: false
                 }) do
              {:ok, _grant} -> :unexpected_export_authority
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        end)
      end)

    assert_receive {:calendar_backend, actor_backend}, 5000
    await_user_lock(actor_backend, revoker_backend, deadline())
    assert Task.yield(actor, 0) == nil
    send(revoker_pid, :commit)
    assert {:ok, :ok} = Task.await(revoker, 5000)
    assert {:error, :forbidden} = Task.await(actor, 5000)
  end

  test "a session expiring during its User authority wait cannot authorize an effect", %{
    account: account,
    subject: subject
  } do
    expires_at = DateTime.add(DateTime.utc_now(), 2, :second)

    unboxed(fn ->
      Repo.update_all(from(s in Session, where: s.id == ^account.session.id),
        set: [expires_at: expires_at]
      )
    end)

    parent = self()

    locker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(u in User, where: u.id == ^account.user.id, lock: "FOR NO KEY UPDATE"))
            send(parent, {:user_locked, self(), backend_pid()})

            receive do
              :commit -> :ok
            after
              10_000 -> raise "calendar expiry barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:user_locked, locker_pid, locker_backend}, 5000

    actor =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            send(parent, {:calendar_backend, backend_pid()})

            case Accounts.lock_calendar_actor(%CalendarActorLockQuery{
                   subject: subject,
                   deadline_ms: deadline(),
                   require_step_up?: false
                 }) do
              {:ok, _grant} -> :unexpected_export_authority
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        end)
      end)

    assert_receive {:calendar_backend, actor_backend}, 5000
    await_user_lock(actor_backend, locker_backend, deadline())
    wait_expiry(expires_at)
    send(locker_pid, :commit)
    assert {:ok, :ok} = Task.await(locker, 5000)
    assert {:error, :forbidden} = Task.await(actor, 5000)
  end

  defp await_user_lock(pid, blocker, deadline) do
    rows =
      unboxed(fn ->
        Repo.query!(
          "SELECT wait_event_type,query,pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid=$1",
          [pid]
        ).rows
      end)

    case rows do
      [["Lock", query, blockers]] ->
        assert query =~ ~s(FROM "users")
        assert query =~ "FOR NO KEY UPDATE"
        assert blocker in blockers

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("calendar actor did not wait for its exact User fence")

        Process.sleep(10)
        await_user_lock(pid, blocker, deadline)
    end
  end

  defp wait_expiry(at) do
    if DateTime.compare(DateTime.utc_now(), at) == :lt do
      Process.sleep(20)
      wait_expiry(at)
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
    pid
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 10_000
  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
