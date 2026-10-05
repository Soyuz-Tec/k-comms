defmodule CommsCore.SharedDocuments.RgaTest do
  use ExUnit.Case, async: true
  alias CommsCore.SharedDocuments.Rga
  @first "00000000-0000-4000-8000-000000000001"
  @second "00000000-0000-4000-8000-000000000002"
  @third "00000000-0000-4000-8000-000000000003"

  test "simultaneous insertions converge independently of receipt arrival order" do
    {:ok, base, _, _, _} = Rga.apply([], [change(nil, [], "ab")], @first, 1)
    anchor = @first <> ":0"
    {:ok, left, _, _, _} = Rga.apply(base, [change(anchor, [], "X")], @second, 2)
    {:ok, left, content, _, _} = Rga.apply(left, [change(anchor, [], "Y")], @third, 3)
    {:ok, right, _, _, _} = Rga.apply(base, [change(anchor, [], "Y")], @third, 3)
    {:ok, right, ^content, _, _} = Rga.apply(right, [change(anchor, [], "X")], @second, 2)
    assert left == right
    assert content == "aYXb"
  end

  test "deleting the original selection preserves a concurrent insertion and its tombstoned anchor" do
    {:ok, base, _, _, _} = Rga.apply([], [change(nil, [], "abc")], @first, 1)
    anchor = @first <> ":0"
    ids = [anchor, @first <> ":1"]
    {:ok, deleted, _, _, _} = Rga.apply(base, [change(nil, ids, "")], @second, 2)

    {:ok, deleted_then_inserted, content, _, _} =
      Rga.apply(deleted, [change(anchor, [], "NEW")], @third, 3)

    {:ok, inserted, _, _, _} = Rga.apply(base, [change(anchor, [], "NEW")], @third, 3)

    {:ok, inserted_then_deleted, ^content, _, _} =
      Rga.apply(inserted, [change(nil, ids, "")], @second, 2)

    assert inserted_then_deleted == deleted_then_inserted
    assert content == "NEWc"
    assert Enum.find(inserted_then_deleted, &(&1["id"] == anchor))["deleted"]
  end

  test "insertion dependencies must be committed before another operation uses their atoms" do
    anchor = @second <> ":0"

    assert {:error, :unknown_document_atom} =
             Rga.apply([], [change(anchor, [], "child")], @third, 2)

    {:ok, parent, _, _, _} = Rga.apply([], [change(nil, [], "P")], @second, 1)
    assert {:ok, _, "Pchild", _, _} = Rga.apply(parent, [change(anchor, [], "child")], @third, 2)
  end

  test "a client cannot fabricate foreign or cyclic parents or redeclare committed atom identity" do
    assert {:error, :unknown_document_atom} =
             Rga.apply([], [change(@first <> ":0", [], "self")], @first, 1)

    {:ok, base, _, _, _} = Rga.apply([], [change(nil, [], "owned")], @first, 1)

    assert {:error, :unknown_document_atom} =
             Rga.apply(base, [change(nil, [@third <> ":0"], "")], @second, 2)

    assert {:error, :document_capacity_exceeded} =
             Rga.apply(base, [change(nil, [], "replace")], @first, 2)
  end

  test "emoji, supplementary scalars and combining marks survive independent edits" do
    {:ok, base, "A😀éZ", inserted, _} = Rga.apply([], [change(nil, [], "A😀éZ")], @first, 1)
    assert length(inserted) == 5
    assert Enum.at(inserted, 1)["text"] == "😀"

    assert {:ok, _, "A😀éZ", _, _} =
             Rga.apply(
               base,
               [change(@first <> ":1", [@first <> ":2", @first <> ":3"], "é")],
               @second,
               2
             )
  end

  test "capacity exhaustion refuses an entire operation without compacting tombstones" do
    {:ok, base, _, _, _} =
      Rga.apply([], [change(nil, [], String.duplicate("a", 2_048))], @first, 1)

    assert {:error, :invalid_document_operation} =
             Rga.apply(base, [change(nil, [], String.duplicate("b", 2_049))], @second, 2)

    assert {:ok, deleted, "", [], _} =
             Rga.apply(base, [change(nil, Enum.map(base, & &1["id"]), "")], @second, 2)

    assert length(deleted) == 2_048
    assert Enum.all?(deleted, & &1["deleted"])
  end

  test "extra lineage metadata, duplicate selected IDs and malformed text are rejected" do
    assert {:error, :invalid_document_operation} =
             Rga.apply([], [Map.put(change(nil, [], "x"), "author_user_ids", [])], @first, 1)

    id = @first <> ":0"

    assert {:error, :invalid_document_operation} =
             Rga.apply([], [change(nil, [id, id], "")], @second, 2)

    assert {:error, :invalid_document_operation} =
             Rga.apply([], [change(nil, [], <<255>>)], @first, 1)

    assert {:error, :invalid_document_operation} =
             Rga.apply([], [change(nil, [], "\0")], @first, 1)
  end

  defp change(anchor, ids, text),
    do: %{"after_id" => anchor, "delete_ids" => ids, "insert" => text}
end
