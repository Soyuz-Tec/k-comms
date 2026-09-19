defmodule CommsCore.WhiteboardCapacityTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Governance, Whiteboards}
  alias CommsCore.Whiteboards.{Operation, Snapshot, Whiteboard}
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  setup do
    account = Fixtures.account_fixture()
    %{account: account, subject: Fixtures.subject(account)}
  end

  test "cumulative scene count includes tombstones, preserves retries, and clear recovers under hold",
       ctx do
    for batch <- 0..24 do
      elements = for n <- 1..200, do: Map.put(element(batch * 200 + n), "isDeleted", true)
      assert {:ok, _, :created} = append(ctx, "count-batch-#{batch}", elements)
    end

    assert {:error, :whiteboard_capacity_exceeded} =
             append(ctx, "count-overflow", [element(5001)])

    assert {:ok, _, :created} = append(ctx, "count-replace", [Map.put(element(1), "version", 2)])

    assert {:ok, _, :duplicate} =
             append(ctx, "count-replace", [Map.put(element(1), "version", 2)])

    before_count = Repo.aggregate(Operation, :count)
    Fixtures.step_up(ctx.account)

    assert {:ok, _} =
             Governance.create_legal_hold(
               %{
                 name: "Capacity history hold",
                 scope_type: "tenant",
                 reason: "Preserve drawing history"
               },
               ctx.subject
             )

    assert {:ok, clear, :created} = clear(ctx)
    assert Repo.aggregate(Operation, :count) == before_count + 1

    assert {:ok, %{snapshot: %{elements: []}, operations: []}} =
             Whiteboards.list_operations(ctx.account.conversation.id, ctx.subject, snapshot: true)

    assert {:error, :stale_whiteboard_generation} = append(ctx, "stale-epoch", [element(5001)])
    assert {:ok, next, :created} = append(ctx, "after-clear", [element(5001)], clear.sequence)
    assert next.sequence == clear.sequence + 1
    assert Repo.aggregate(Operation, :count) == before_count + 2
  end

  test "cumulative encoded bytes are bounded even when every update fits its own limit", ctx do
    for batch <- 0..4 do
      elements =
        for n <- 1..8, do: Map.put(element(batch * 8 + n), "text", String.duplicate("a", 50_000))

      assert {:ok, _, :created} = append(ctx, "bytes-batch-#{batch}", elements)
    end

    count = Repo.aggregate(Operation, :count)
    too_large = for n <- 41..43, do: Map.put(element(n), "text", String.duplicate("a", 50_000))
    assert {:error, :whiteboard_capacity_exceeded} = append(ctx, "bytes-overflow", too_large)
    assert Repo.aggregate(Operation, :count) == count
    assert {:ok, _, :created} = clear(ctx)
  end

  test "operation limit applies to an epoch and clear preserves monotonic history", ctx do
    assert {:ok, first, :created} = append(ctx, "epoch-first", [element(1)])
    board = Repo.get_by!(Whiteboard, conversation_id: ctx.account.conversation.id)
    Repo.update_all(from(w in Whiteboard, where: w.id == ^board.id), set: [sequence: 100_000])

    assert {:error, :whiteboard_capacity_exceeded} = append(ctx, "epoch-full", [element(2)])
    assert {:ok, duplicate, :duplicate} = append(ctx, "epoch-first", [element(1)])
    assert duplicate.id == first.id
    assert {:ok, clear, :created} = clear(ctx)
    assert clear.sequence == 100_001
    assert {:ok, next, :created} = append(ctx, "epoch-new", [element(2)], clear.sequence)
    assert next.sequence == 100_002
    assert Repo.get!(Operation, first.id).payload["elements"] != []
  end

  test "an oversized legacy scene can clear without reading its payload and replay never crosses epochs",
       ctx do
    assert {:ok, _, :created} = append(ctx, "legacy-initial", [element(1)])
    board = Repo.get_by!(Whiteboard, conversation_id: ctx.account.conversation.id)
    oversized = for n <- 1..5_001, do: element(n)

    %Snapshot{}
    |> Snapshot.changeset(%{
      whiteboard_id: board.id,
      tenant_id: board.tenant_id,
      conversation_id: board.conversation_id,
      through_sequence: 1,
      generation_sequence: 0,
      elements: %{"elements" => oversized}
    })
    |> Repo.insert!()

    assert {:error, :whiteboard_capacity_exceeded} =
             append(ctx, "legacy-overflow", [element(6000)])

    assert {:ok, clear, :created} = clear(ctx)
    # Simulate cache invalidation. Old oversized operations are retained but must
    # not be folded into the new epoch after losing its snapshot.
    Repo.delete_all(from(s in Snapshot, where: s.whiteboard_id == ^board.id))

    Repo.update_all(from(o in Operation, where: o.whiteboard_id == ^board.id and o.sequence == 1),
      set: [payload: %{"elements" => oversized}]
    )

    assert {:ok, _, :created} = append(ctx, "legacy-recovered", [element(6000)], clear.sequence)
    assert {:ok, page} = Whiteboards.list_operations(board.conversation_id, ctx.subject)
    assert Enum.map(page.operations, & &1.sequence) == [clear.sequence, clear.sequence + 1]
  end

  defp append(ctx, id, elements, base_sequence \\ 0),
    do:
      Whiteboards.append_operation(
        ctx.account.conversation.id,
        %{
          client_operation_id: id,
          kind: "scene.update",
          base_sequence: base_sequence,
          payload: %{"elements" => elements}
        },
        ctx.subject
      )

  defp clear(ctx),
    do:
      Whiteboards.append_operation(
        ctx.account.conversation.id,
        %{client_operation_id: "capacity-clear", kind: "board.clear", payload: %{}},
        ctx.subject
      )

  defp element(n),
    do: %{
      "id" => "element-#{n}",
      "type" => "text",
      "version" => 1,
      "versionNonce" => 1,
      "link" => nil,
      "customData" => nil
    }
end
