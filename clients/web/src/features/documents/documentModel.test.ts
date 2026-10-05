import { describe, expect, it } from "vitest";
import type { DocumentAtom, DocumentEdit, DocumentOperation, SharedDocument } from "../../types/sharedDocuments";
import { atomText, committedApply, optimisticApply, orderAtoms, selectionIds, selectionOffsets, textChanges } from "./documentModel";
const first = "00000000-0000-4000-8000-000000000001", second = "00000000-0000-4000-8000-000000000002", third = "00000000-0000-4000-8000-000000000003";
const edit = (id: string, after: string | null, insert: string, deletes: string[] = []): DocumentEdit => ({ client_operation_id: id, generation: 1, base_version: 1, kind: "edit", changes: [{ after_id: after, insert, delete_ids: deletes }] });
const document = (atoms: DocumentAtom[] = []): SharedDocument => ({ id: "doc", conversation_id: "conversation", title: "Notes", content: atomText(atoms), atoms, generation: 1, version: 1, updated_at: "2026-10-05T00:00:00Z", readonly: false });
const receipt = (input: DocumentEdit, version: number, atoms: DocumentAtom[]): DocumentOperation => ({ document_id: "doc", conversation_id: "conversation", client_operation_id: input.client_operation_id,
  generation: 1, version, kind: "edit", title: null, inserted_atoms: atoms.filter(atom => atom.id.startsWith(input.client_operation_id + ":")), deleted_atom_ids: input.changes?.flatMap(change => change.delete_ids) || [], inserted_at: "2026-10-05T00:01:00Z" });

describe("server-owned document RGA client reconciliation", () => {
  it("converges simultaneous edits in committed sequence order regardless of receipt arrival projection", () => {
    const base = optimisticApply([], edit(first, null, "ab"), 1);
    const a = edit(second, first + ":0", "X"), b = edit(third, first + ":0", "Y");
    const left = optimisticApply(optimisticApply(base, a, 2), b, 3);
    const right = optimisticApply(optimisticApply(base, b, 3), a, 2);
    expect(left).toEqual(right); expect(atomText(left)).toBe("aYXb");
  });
  it("deletes only the original selected characters and preserves concurrent inserted text", () => {
    const base = optimisticApply([], edit(first, null, "abc"), 1);
    const remove = edit(second, null, "", [first + ":0", first + ":1"]);
    const insert = edit(third, first + ":0", "NEW");
    expect(atomText(optimisticApply(optimisticApply(base, remove, 2), insert, 3))).toBe("NEWc");
    expect(optimisticApply(optimisticApply(base, remove, 2), insert, 3)).toEqual(optimisticApply(optimisticApply(base, insert, 3), remove, 2));
  });
  it("preserves server atom order when a fresh snapshot already contains an unknown acknowledgement", () => {
    const input = edit(first, null, "once");
    const committed = optimisticApply([], input, 9);
    expect(optimisticApply(committed, input, 10)).toEqual(committed);
    expect(atomText(committed)).toBe("once");
  });
  it("keeps dependent local anchors through parent acknowledgement and remote insertion", () => {
    const parent = edit(first, null, "A"), child = edit(second, first + ":0", "B");
    const before = optimisticApply(optimisticApply([], parent, 2), child, 3);
    expect(atomText(before)).toBe("AB");
    const remote = optimisticApply(optimisticApply([], parent, 2), edit(third, first + ":0", "R"), 3);
    expect(atomText(optimisticApply(remote, child, 4))).toBe("ABR");
  });
  it("maps UTF-16 editor offsets to emoji and combining scalar IDs without splitting surrogate pairs", () => {
    const atoms = optimisticApply([], edit(first, null, "A😀éZ"), 1);
    expect(textChanges(atoms, [{ from: 1, to: 3, insert: "🙂" }])).toEqual([{ after_id: first + ":0", delete_ids: [first + ":1"], insert: "🙂" }]);
    expect(() => textChanges(atoms, [{ from: 2, to: 3, insert: "" }])).toThrow(/Unicode/);
    expect(textChanges(atoms, [{ from: 3, to: 5, insert: "é" }])[0]!.delete_ids).toEqual([first + ":2", first + ":3"]);
    expect(selectionIds(atoms, 3, 5)).toEqual({ anchor_id: first + ":1", head_id: first + ":3" });
    expect(selectionOffsets(atoms, first + ":1", first + ":3")).toEqual({ anchor: 3, head: 5 });
  });
  it("refuses foreign/cyclic/duplicate atom graphs and missing local anchors", () => {
    const atoms = optimisticApply([], edit(first, null, "x"), 1);
    expect(() => orderAtoms([...atoms, atoms[0]!])).toThrow(/Invalid/);
    expect(() => orderAtoms([{ ...atoms[0]!, after_id: atoms[0]!.id }])).toThrow(/Invalid/);
    expect(() => orderAtoms([{ ...atoms[0]!, after_id: third + ":0" }])).toThrow(/Missing/);
    expect(() => optimisticApply(atoms, edit(second, third + ":0", "x"), 2)).toThrow(/anchor/);
  });
  it("ordered replay refuses a missing receipt or an erased generation and ignores older receipts", () => {
    const input = edit(first, null, "hello"), atoms = optimisticApply([], input, 2), operation = receipt(input, 2, atoms);
    expect(committedApply(document(), operation).content).toBe("hello");
    expect(() => committedApply(document(), { ...operation, version: 3 })).toThrow(/gap/);
    expect(() => committedApply(document(), { ...operation, generation: 2 })).toThrow(/generation/);
    const current = committedApply(document(), operation);
    expect(committedApply(current, operation)).toBe(current);
  });
  it("rejects bounded overflow and malformed Unicode while retaining tombstones", () => {
    expect(() => textChanges([], [{ from: 0, to: 0, insert: "x".repeat(2049) }])).toThrow(/2,048/);
    expect(() => textChanges([], [{ from: 0, to: 0, insert: "\ud800" }])).toThrow(/Unicode/);
    const base = optimisticApply([], edit(first, null, "private"), 1);
    const removed = optimisticApply(base, edit(second, null, "", base.map(atom => atom.id)), 2);
    expect(atomText(removed)).toBe(""); expect(removed).toHaveLength(base.length); expect(removed.every(atom => atom.deleted)).toBe(true);
  });
});
