defmodule CommsCore.AdmissionLockProofTest do
  use ExUnit.Case, async: false
  alias CommsCore.{AdmissionQuotas, Repo, RetainedAdmissionLockProof}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  for namespace <- [:admission, :unrelated_author] do
    @namespace namespace
    test "exact retained admission proof distinguishes #{@namespace} and another tenant" do
      tenant = Ecto.UUID.generate()
      parent = self()

      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              lock(@namespace, tenant)
              send(parent, {:holder, self(), backend_pid()})

              receive do
                :release -> :ok
              after
                5_000 -> raise "admission holder timed out"
              end
            end)
          end)
        end)

      assert_receive {:holder, holder_pid, holder_backend}, 5_000

      waiter =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              send(parent, {:waiter, backend_pid()})
              lock(@namespace, tenant)
            end)
          end)
        end)

      try do
        assert_receive {:waiter, waiter_backend}, 5_000
        await_blocker(waiter_backend, holder_backend, System.monotonic_time(:millisecond) + 5_000)

        assert RetainedAdmissionLockProof.waiting_on_admission?(
                 waiter_backend,
                 holder_backend,
                 tenant
               ) == (@namespace == :admission)

        refute RetainedAdmissionLockProof.waiting_on_admission?(
                 waiter_backend,
                 holder_backend,
                 Ecto.UUID.generate()
               )

        send(holder_pid, :release)
        assert {:ok, :ok} = Task.await(holder, 5_000)
        assert {:ok, :ok} = Task.await(waiter, 5_000)
      after
        send(holder_pid, :release)
        Task.shutdown(holder, :brutal_kill)
        Task.shutdown(waiter, :brutal_kill)
      end
    end
  end

  defp lock(:admission, tenant), do: AdmissionQuotas.lock_tenant(tenant)

  defp lock(:unrelated_author, tenant) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [
      "k-comms:unrelated-author:v1:" <> tenant
    ])

    :ok
  end

  defp await_blocker(waiter, holder, deadline) do
    %{rows: [[blocking?]]} =
      unboxed(fn -> Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, holder]) end)

    if not blocking? do
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("no actual retained advisory wait"),
        else:
          (
            Process.sleep(10)
            await_blocker(waiter, holder, deadline)
          )
    end
  end

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()", []).rows |> hd() |> hd()
  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
