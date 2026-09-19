defmodule CommsCore.WhiteboardErasureConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Repo, Whiteboards}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Whiteboards.Snapshot
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  setup do
    previous = Application.get_env(:comms_core, :whiteboard_snapshot_interval)
    Application.put_env(:comms_core, :whiteboard_snapshot_interval, 1)
    account = unboxed(fn -> Fixtures.account_fixture() end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :whiteboard_snapshot_interval, previous),
        else: Application.delete_env(:comms_core, :whiteboard_snapshot_interval)

      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
      end)
    end)

    %{account: account}
  end

  test "erasure waits for concurrent inline reconstruction then removes its snapshot", %{
    account: account
  } do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:comms_core, :repo, :query],
      fn _, _, metadata, _ ->
        if String.contains?(metadata.query, ~s(INSERT INTO "whiteboard_snapshots")) do
          send(parent, {:snapshot_written, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> raise "snapshot barrier timeout"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    writer = Task.async(fn -> unboxed(fn -> append(account, "private-element") end) end)
    assert_receive {:snapshot_written, pid}, 5_000
    eraser = Task.async(fn -> unboxed(fn -> erase(account) end) end)
    assert Task.yield(eraser, 100) == nil
    send(pid, :continue)
    assert {:ok, _, :created} = Task.await(writer, 5_000)
    assert {:ok, {:ok, _}} = Task.await(eraser, 5_000)

    unboxed(fn ->
      refute Repo.get_by(Snapshot, conversation_id: account.conversation.id)

      assert {:ok, %{snapshot: nil, operations: [operation]}} =
               Whiteboards.list_operations(account.conversation.id, Fixtures.subject(account),
                 snapshot: true
               )

      assert operation.payload == %{"elements" => []}
    end)
  end

  test "a rebuild after erasure uses only the sanitized history", %{account: account} do
    unboxed(fn -> assert {:ok, _, :created} = append(account, "private-element") end)
    parent = self()

    eraser =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            {:ok, result} =
              Whiteboards.erase_for_governance(
                account.tenant.id,
                :user,
                account.user.id,
                DateTime.utc_now()
              )

            send(parent, {:erased_before_commit, self()})

            receive do
              :continue -> result
            after
              5_000 -> raise "erasure barrier timeout"
            end
          end)
        end)
      end)

    assert_receive {:erased_before_commit, pid}, 5_000
    writer = Task.async(fn -> unboxed(fn -> append(account, "new-element") end) end)
    assert Task.yield(writer, 100) == nil
    send(pid, :continue)
    assert {:ok, _} = Task.await(eraser, 5_000)
    assert {:ok, _, :created} = Task.await(writer, 5_000)

    unboxed(fn ->
      assert {:ok, %{snapshot: %{elements: elements}}} =
               Whiteboards.list_operations(account.conversation.id, Fixtures.subject(account),
                 snapshot: true
               )

      assert Enum.map(elements, & &1["id"]) == ["new-element"]
    end)
  end

  defp erase(account),
    do:
      Repo.transaction(fn ->
        Whiteboards.erase_for_governance(
          account.tenant.id,
          :user,
          account.user.id,
          DateTime.utc_now()
        )
      end)

  defp append(account, id),
    do:
      Whiteboards.append_operation(
        account.conversation.id,
        %{
          client_operation_id: "operation-#{id}",
          kind: "scene.update",
          payload: %{
            "elements" => [
              %{"id" => id, "type" => "rectangle", "version" => 1, "versionNonce" => 1}
            ]
          }
        },
        Fixtures.subject(account)
      )

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
