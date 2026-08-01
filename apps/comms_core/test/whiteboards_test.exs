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
