defmodule CommsCore.WhiteboardsTest do
  use CommsCore.DataCase, async: false

  @moduletag :whiteboard
  @moduletag :integration

  alias CommsCore.Whiteboards
  alias CommsCore.Whiteboards.{Operation, Whiteboard}
  alias CommsTestSupport.Fixtures

  test "durably appends, replays, deduplicates, and clears a conversation board" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    conversation_id = account.conversation.id
    element = element("element-one", 1, 120)

    assert {:ok, created, :created} =
             Whiteboards.append_operation(
               conversation_id,
               %{
                 client_operation_id: "operation-one",
                 kind: "scene.update",
                 payload: %{"elements" => [element]}
               },
               subject
             )

    assert created.sequence == 1
    assert created.payload["elements"] == [element]

    assert {:ok, duplicate, :duplicate} =
             Whiteboards.append_operation(
               conversation_id,
               %{
                 client_operation_id: "operation-one",
                 kind: "scene.update",
                 payload: %{"elements" => [element]}
               },
               subject
             )

    assert duplicate.id == created.id
    assert Repo.aggregate(Operation, :count) == 1

    assert {:error, :idempotency_conflict} =
             Whiteboards.append_operation(
               conversation_id,
               %{
                 client_operation_id: "operation-one",
                 kind: "scene.update",
                 payload: %{"elements" => [element("different-element", 1, 99)]}
               },
               subject
             )

    assert {:ok, _clear, :created} =
             Whiteboards.append_operation(
               conversation_id,
               %{client_operation_id: "operation-clear", kind: "board.clear", payload: %{}},
               subject
             )

    replacement = element("element-two", 1, 90)

    assert {:error, :stale_whiteboard_generation} =
             Whiteboards.append_operation(
               conversation_id,
               %{
                 client_operation_id: "operation-stale-after-clear",
                 base_sequence: 1,
                 kind: "scene.update",
                 payload: %{"elements" => [replacement]}
               },
               subject
             )

    assert {:ok, replacement_operation, :created} =
             Whiteboards.append_operation(
               conversation_id,
               %{
                 client_operation_id: "operation-two",
                 base_sequence: 2,
                 kind: "scene.update",
                 payload: %{"elements" => [replacement]}
               },
               subject
             )

    assert replacement_operation.sequence == 3
    assert {:ok, page} = Whiteboards.list_operations(conversation_id, subject)
    assert Enum.map(page.operations, & &1.kind) == ["board.clear", "scene.update"]
    assert page.next_after_sequence == 3
    refute page.has_more
  end

  describe "snapshots" do
    setup do
      previous = Application.get_env(:comms_core, :whiteboard_snapshot_interval)
      Application.put_env(:comms_core, :whiteboard_snapshot_interval, 3)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:comms_core, :whiteboard_snapshot_interval)
        else
          Application.put_env(:comms_core, :whiteboard_snapshot_interval, previous)
        end
      end)

      account = Fixtures.account_fixture()
      %{subject: Fixtures.subject(account), conversation_id: account.conversation.id}
    end

    test "a snapshot reconstructs exactly what a full replay would", %{
      subject: subject,
      conversation_id: conversation_id
    } do
      # Same element edited repeatedly, plus a second element, so the result
      # depends on the merge rule rather than on simple accumulation.
      for step <- 1..6 do
        append(conversation_id, subject, "snapshot-op-#{step}", [
          element("shared-element", step, 500 - step),
          element("only-element-#{step}", 1, 10)
        ])
      end

      assert {:ok, replayed} = Whiteboards.list_operations(conversation_id, subject)

      assert {:ok, compacted} =
               Whiteboards.list_operations(conversation_id, subject, snapshot: true)

      assert %{elements: elements, through_sequence: through} = compacted.snapshot
      assert through > 0

      # The scene a snapshot client ends with must equal the scene a replaying
      # client ends with. If these ever diverge, compaction is silently
      # corrupting boards.
      assert scene_of(elements, compacted.operations) == scene_of([], replayed.operations)
    end

    test "the snapshot is withheld until the caller opts in", %{
      subject: subject,
      conversation_id: conversation_id
    } do
      for step <- 1..5,
          do:
            append(conversation_id, subject, "snapshot-op-#{step}", [
              element("alpha-element", step, 5)
            ])

      assert {:ok, default_page} = Whiteboards.list_operations(conversation_id, subject)
      assert default_page.snapshot == nil

      # An image rolled back to before snapshots must still receive a complete
      # scene, so the old full-replay path has to stay intact.
      assert length(default_page.operations) == 5
    end

    test "an incremental caller is never handed a snapshot", %{
      subject: subject,
      conversation_id: conversation_id
    } do
      for step <- 1..5,
          do:
            append(conversation_id, subject, "snapshot-op-#{step}", [
              element("alpha-element", step, 5)
            ])

      assert {:ok, page} =
               Whiteboards.list_operations(conversation_id, subject,
                 snapshot: true,
                 after_sequence: 2
               )

      # It already holds a scene; replacing it wholesale would discard edits it
      # applied locally but has not read back.
      assert page.snapshot == nil
      assert Enum.map(page.operations, & &1.sequence) == [3, 4, 5]
    end

    test "a clear invalidates the snapshot rather than resurrecting the scene", %{
      subject: subject,
      conversation_id: conversation_id
    } do
      for step <- 1..4,
          do:
            append(conversation_id, subject, "snapshot-op-#{step}", [
              element("alpha-element", step, 5)
            ])

      assert {:ok, before_clear} =
               Whiteboards.list_operations(conversation_id, subject, snapshot: true)

      assert before_clear.snapshot != nil

      assert {:ok, clear, :created} =
               Whiteboards.append_operation(
                 conversation_id,
                 %{
                   client_operation_id: "snapshot-clear-marker",
                   kind: "board.clear",
                   payload: %{}
                 },
                 subject
               )

      assert {:ok, after_clear} =
               Whiteboards.list_operations(conversation_id, subject, snapshot: true)

      # Serving the pre-clear snapshot here would restore work a collaborator
      # deleted for everyone.
      assert after_clear.snapshot == nil
      assert Enum.map(after_clear.operations, & &1.sequence) == [clear.sequence]
    end

    test "a snapshot taken after a clear covers only the new generation", %{
      subject: subject,
      conversation_id: conversation_id
    } do
      for step <- 1..4,
          do:
            append(conversation_id, subject, "snapshot-op-#{step}", [
              element("old-element", step, 5)
            ])

      assert {:ok, clear, :created} =
               Whiteboards.append_operation(
                 conversation_id,
                 %{
                   client_operation_id: "snapshot-clear-marker",
                   kind: "board.clear",
                   payload: %{}
                 },
                 subject
               )

      for step <- 1..4 do
        append(
          conversation_id,
          subject,
          "post-clear-op-#{step}",
          [element("new-element", step, 5)],
          base_sequence: clear.sequence
        )
      end

      assert {:ok, page} = Whiteboards.list_operations(conversation_id, subject, snapshot: true)
      assert %{elements: elements} = page.snapshot

      ids = scene_of(elements, page.operations) |> Enum.map(& &1["id"])
      assert "new-element" in ids
      refute "old-element" in ids
    end
  end

  test "serializes concurrent collaborators without sequence loss" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    results =
      1..12
      |> Task.async_stream(
        fn number ->
          Whiteboards.append_operation(
            account.conversation.id,
            %{
              client_operation_id: "concurrent-operation-#{number}",
              kind: "scene.update",
              payload: %{"elements" => [element("element-#{number}", 1, number)]}
            },
            subject
          )
        end,
        max_concurrency: 6,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _, :created}, &1))

    assert results |> Enum.map(fn {:ok, operation, _} -> operation.sequence end) |> Enum.sort() ==
             Enum.to_list(1..12)
  end

  test "rejects non-members and unsafe or unsupported SDK scene data" do
    account = Fixtures.account_fixture()
    outsider = Fixtures.account_fixture()

    attrs = %{
      client_operation_id: "operation-forbidden",
      kind: "scene.update",
      payload: %{"elements" => [element("element-one", 1, 10)]}
    }

    assert {:error, :forbidden} =
             Whiteboards.append_operation(
               account.conversation.id,
               attrs,
               Fixtures.subject(outsider)
             )

    unsafe = element("element-unsafe", 1, 11) |> Map.put("link", "javascript:alert(1)")

    assert {:error, :invalid_whiteboard_operation} =
             Whiteboards.append_operation(
               account.conversation.id,
               %{
                 attrs
                 | client_operation_id: "operation-unsafe",
                   payload: %{"elements" => [unsafe]}
               },
               Fixtures.subject(account)
             )

    image = element("element-image", 1, 12) |> Map.put("type", "image")

    assert {:error, :invalid_whiteboard_operation} =
             Whiteboards.append_operation(
               account.conversation.id,
               %{
                 attrs
                 | client_operation_id: "operation-image",
                   payload: %{"elements" => [image]}
               },
               Fixtures.subject(account)
             )
  end

  test "contributes user neutralization and conversation deletion to governance transactions" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, _operation, :created} =
             Whiteboards.append_operation(
               account.conversation.id,
               %{
                 client_operation_id: "operation-to-erase",
                 kind: "scene.update",
                 payload: %{"elements" => [element("private-element", 1, 7)]}
               },
               subject
             )

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, {:ok, %{whiteboard_operations_neutralized: 1}}} =
             Repo.transaction(fn ->
               Whiteboards.erase_for_governance(
                 account.tenant.id,
                 :user,
                 account.user.id,
                 timestamp
               )
             end)

    assert {:ok, %{operations: [neutralized]}} =
             Whiteboards.list_operations(account.conversation.id, subject)

    assert neutralized.payload == %{"elements" => []}

    assert {:ok,
            {:ok,
             %{
               whiteboards_deleted: 1,
               whiteboard_operations_deleted: 1
             }}} =
             Repo.transaction(fn ->
               Whiteboards.erase_for_governance(
                 account.tenant.id,
                 :conversation,
                 account.conversation.id,
                 timestamp
               )
             end)

    refute Repo.get_by(Whiteboard,
             tenant_id: account.tenant.id,
             conversation_id: account.conversation.id
           )

    assert {:ok, %{operations: []}} =
             Whiteboards.list_operations(account.conversation.id, subject)
  end

  defp append(conversation_id, subject, client_operation_id, elements, opts \\ []) do
    attrs =
      %{
        client_operation_id: client_operation_id,
        kind: "scene.update",
        payload: %{"elements" => elements}
      }
      |> Map.merge(Map.new(opts))

    assert {:ok, operation, :created} =
             Whiteboards.append_operation(conversation_id, attrs, subject)

    operation
  end

  # Mirrors the client's projection: first-seen order, higher version wins, and
  # equal versions settle on the lower nonce.
  defp scene_of(elements, operations) do
    operations
    |> Enum.reduce(elements, fn
      %{kind: "board.clear"}, _scene ->
        []

      %{kind: "scene.update", payload: payload}, scene ->
        merge_elements(scene, payload["elements"] || [])
    end)
  end

  defp merge_elements(scene, incoming) do
    Enum.reduce(incoming, scene, fn element, acc ->
      case Enum.find_index(acc, &(&1["id"] == element["id"])) do
        nil ->
          acc ++ [element]

        position ->
          current = Enum.at(acc, position)

          if wins?(current, element),
            do: List.replace_at(acc, position, element),
            else: acc
      end
    end)
  end

  defp wins?(current, incoming) do
    if incoming["version"] == current["version"] do
      incoming["versionNonce"] < current["versionNonce"]
    else
      incoming["version"] > current["version"]
    end
  end

  defp element(id, version, nonce) do
    %{
      "id" => id,
      "type" => "rectangle",
      "version" => version,
      "versionNonce" => nonce,
      "link" => nil,
      "customData" => nil,
      "x" => 10,
      "y" => 20,
      "width" => 100,
      "height" => 80,
      "isDeleted" => false
    }
  end
end
