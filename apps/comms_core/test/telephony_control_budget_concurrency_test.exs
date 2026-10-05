defmodule CommsCore.TelephonyControlBudgetConcurrencyTest.Provider do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract

  def capabilities(), do: %{hold: %{supported: true, reason: nil}}
  def authorize_destination(_), do: {:error, :telephony_destination_forbidden}
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}
  def cleanup_call(_), do: {:error, :telephony_provider_unavailable}
  def bound_call_status(_), do: {:error, :telephony_provider_unavailable}

  def execute_control(%CommsCore.Telephony.ControlRequest{} = request) do
    parent = Process.get(:control_budget_test_parent)
    send(parent, {:control_effect, request.command_id, request.action})
    {:ok, :submitted}
  end
end

defmodule CommsCore.TelephonyControlBudgetConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Repo, Telephony}
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.Tenant
  alias CommsCore.Telephony.{Call, ControlCommand, ControlRequest}
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.TelephonyControlWorker
  alias Ecto.Adapters.SQL.Sandbox
  @moduletag :integration
  @moduletag :concurrency
  @moduletag :call

  setup do
    previous = Application.fetch_env(:comms_core, :telephony_control_adapter)
    previous_key = Application.fetch_env(:comms_core, :telephony_control_fingerprint_key)

    Application.put_env(:comms_core, :telephony_control_adapter, __MODULE__.Provider)

    Application.put_env(
      :comms_core,
      :telephony_control_fingerprint_key,
      String.duplicate("k", 32)
    )

    on_exit(fn ->
      restore(:telephony_control_adapter, previous)
      restore(:telephony_control_fingerprint_key, previous_key)
    end)

    account = unboxed(fn -> Fixtures.account_fixture() end)

    on_exit(fn ->
      unboxed(fn ->
        call_ids =
          Repo.all(from(c in Call, where: c.tenant_id == ^account.tenant.id, select: c.id))

        command_ids =
          Repo.all(
            from(c in ControlCommand, where: c.tenant_id == ^account.tenant.id, select: c.id)
          )

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              fragment("?->>'call_id'", j.args) in ^call_ids or
                fragment("?->>'command_id'", j.args) in ^command_ids or
                fragment("?->>'tenant_id' = ?", j.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(from(t in Tenant, where: t.id == ^account.tenant.id))
      end)
    end)

    %{account: account}
  end

  @tag timeout: 45_000
  test "a real call-lock wait consumes the effect budget without submitting a claimed command",
       %{account: account} do
    {call, command} = unboxed(fn -> claimed_hold(account) end)

    elapsed =
      reject_effect_after_call_lock(call, command, fn ->
        blocked_at = System.monotonic_time(:millisecond)

        # Use the real production 30s transaction and 60s command lifetimes.
        # A measured 13s row-lock wait leaves less than the 15s effect + 3s
        # receipt reserve; no test clock or shortened timeout causes rejection.
        Process.sleep(13_000)
        assert System.monotonic_time(:millisecond) - blocked_at >= 13_000
      end)

    assert elapsed >= 13_000
    assert elapsed < 30_000
  end

  @tag timeout: 30_000
  test "session expiry during a real call-lock wait denies effects while the provider budget remains",
       %{account: account} do
    {call, command} = unboxed(fn -> claimed_hold(account) end)

    expires_at =
      unboxed(fn ->
        session = Repo.get!(Session, account.session.id)
        expires_at = DateTime.add(DateTime.utc_now(), 5, :second)
        assert DateTime.compare(expires_at, session.absolute_expires_at) == :lt

        session
        |> Session.changeset(%{expires_at: expires_at})
        |> Repo.update!()

        expires_at
      end)

    elapsed =
      reject_effect_after_call_lock(call, command, fn ->
        # The exact Call blocker proves the worker already passed its initial
        # current-session check. Only the real sliding session deadline expires;
        # the command, call, absolute deadline and effect budget remain live.
        remaining = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
        assert remaining > 0
        Process.sleep(remaining + 100)
        assert DateTime.compare(expires_at, DateTime.utc_now()) == :lt
      end)

    assert elapsed < 12_000

    session = unboxed(fn -> Repo.get!(Session, account.session.id) end)
    assert DateTime.compare(session.absolute_expires_at, DateTime.utc_now()) == :gt
    assert is_nil(session.revoked_at)
  end

  defp reject_effect_after_call_lock(call, command, wait) do
    parent = self()
    release = make_ref()

    locker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(
            fn ->
              Repo.one!(
                from(c in Call,
                  where: c.id == ^call.id and c.tenant_id == ^call.tenant_id,
                  lock: "FOR UPDATE"
                )
              )

              send(parent, {:call_locked, self(), backend_pid()})

              receive do
                {:release_call_lock, ^release} -> :ok
              after
                25_000 -> raise "call-lock barrier timeout"
              end
            end,
            timeout: 30_000
          )
        end)
      end)

    try do
      assert_receive {:call_locked, locker_pid, locker_backend}, 5_000
      assert locker_pid == locker.pid

      worker =
        Task.async(fn ->
          unboxed(fn ->
            Process.put(:control_budget_test_parent, parent)
            started = System.monotonic_time(:millisecond)
            send(parent, {:effect_worker_started, self(), backend_pid()})

            result =
              Telephony.complete_control(command.id, {:execute, false}, TelephonyControlWorker)

            {result, System.monotonic_time(:millisecond) - started}
          end)
        end)

      try do
        assert_receive {:effect_worker_started, worker_pid, worker_backend}, 5_000
        assert worker_pid == worker.pid
        refute worker_backend == locker_backend

        await_call_lock(
          worker_backend,
          locker_backend,
          System.monotonic_time(:millisecond) + 5_000
        )

        assert Task.yield(worker, 100) == nil
        wait.()
        send(locker.pid, {:release_call_lock, release})

        assert {:ok, :ok} = Task.await(locker, 5_000)
        assert {{:error, :telephony_provider_unavailable}, elapsed} = Task.await(worker, 10_000)
        refute_received {:control_effect, _, _}

        {stored, current_call} =
          unboxed(fn -> {Repo.get!(ControlCommand, command.id), Repo.get!(Call, call.id)} end)

        assert DateTime.compare(stored.expires_at, DateTime.utc_now()) == :gt
        assert stored.status == :dispatching
        assert stored.claimed_at == command.claimed_at
        assert is_nil(stored.completed_at)
        assert is_nil(stored.failure_reason)
        assert current_call.status == :answered
        assert current_call.control_state == "connected"
        assert DateTime.compare(current_call.expires_at, DateTime.utc_now()) == :gt
        elapsed
      after
        send(locker.pid, {:release_call_lock, release})
        Task.shutdown(worker, :brutal_kill)
      end
    after
      send(locker.pid, {:release_call_lock, release})
      Task.shutdown(locker, :brutal_kill)
    end
  end

  defp claimed_hold(account) do
    subject = Fixtures.step_up(account)

    suffix =
      System.unique_integer([:positive])
      |> rem(100_000)
      |> Integer.to_string()
      |> String.pad_leading(5, "0")

    assert {:ok, _} =
             Telephony.provision(
               %{
                 phone_number: "+14155" <> suffix,
                 extension: "101",
                 user_id: account.user.id,
                 inbound_trunk_id: "ST_budget_inbound",
                 outbound_trunk_id: "ST_budget_outbound",
                 reason: "Synthetic control budget concurrency fixture"
               },
               subject
             )

    assert {:ok, view, :created} =
             Telephony.start_outbound(
               %{destination: "+14155550200", idempotency_key: "budget-outbound"},
               subject
             )

    call =
      Repo.get!(Call, view.id)
      |> Call.changeset(%{
        status: :answered,
        answered_at: DateTime.utc_now(),
        dispatch_status: :started,
        provider_call_id: "SC_budget_exact"
      })
      |> Repo.update!()

    assert {:ok, receipt} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "budget-hold"},
               subject
             )

    assert {:ok, %ControlRequest{reconcile: false}} =
             Telephony.claim_control(receipt.id, TelephonyControlWorker)

    bindings = %{
      "external" => "external",
      "app" => "app",
      "mixing" => "mixing",
      "holding" => "holding",
      "consult" => "consult",
      "recording" => "recording"
    }

    assert {:ok, %ControlRequest{pbx_state: ^bindings}} =
             Telephony.bind_control(receipt.id, bindings, TelephonyControlWorker)

    command = Repo.get!(ControlCommand, receipt.id)
    assert command.status == :dispatching
    assert is_struct(command.claimed_at, DateTime)
    {call, command}
  end

  defp await_call_lock(worker_backend, locker_backend, deadline) do
    activity =
      unboxed(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT wait_event_type, query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1",
          [worker_backend]
        )
      end)

    waiting_for_call? =
      case activity.rows do
        [["Lock", query, blockers]] when is_binary(query) and is_list(blockers) ->
          String.contains?(query, ~s(FROM "telephony_calls")) and
            String.contains?(query, "FOR UPDATE") and locker_backend in blockers

        _ ->
          false
      end

    unless waiting_for_call? do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("control worker did not wait for the exact call locker")
      else
        Process.sleep(10)
        await_call_lock(worker_backend, locker_backend, deadline)
      end
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
  defp restore(key, {:ok, value}), do: Application.put_env(:comms_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:comms_core, key)
end
