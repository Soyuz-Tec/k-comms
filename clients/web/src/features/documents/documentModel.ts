import type { DocumentAtom, DocumentChange, DocumentEdit, DocumentOperation, SharedDocument } from "../../types/sharedDocuments";
export interface TextChange { from: number; to: number; insert: string }
export const MAX_ATOMS = 32_000;
export function orderAtoms(atoms: readonly DocumentAtom[]): DocumentAtom[] {
  const children = new Map<string | null, DocumentAtom[]>();
  const ids = new Set<string>();
  for (const atom of atoms) {
    if (ids.has(atom.id) || !Number.isSafeInteger(atom.order) || atom.order < 0 || Array.from(atom.text).length !== 1) throw new Error("Invalid document atom");
    ids.add(atom.id);
    const siblings = children.get(atom.after_id) || [];
    siblings.push(atom); children.set(atom.after_id, siblings);
  }
  for (const atom of atoms) if (atom.after_id !== null && !ids.has(atom.after_id)) throw new Error("Missing document parent");
  for (const siblings of children.values()) siblings.sort((a, b) => b.order - a.order || a.id.localeCompare(b.id));
  const result: DocumentAtom[] = [];
  const stack = [...(children.get(null) || [])].reverse();
  const visited = new Set<string>();
  while (stack.length) {
    const atom = stack.pop()!;
    if (visited.has(atom.id)) throw new Error("Cyclic document atoms");
    visited.add(atom.id); result.push(atom);
    stack.push(...(children.get(atom.id) || []).slice().reverse());
  }
  if (result.length !== atoms.length || result.length > MAX_ATOMS) throw new Error("Invalid document graph");
  return result;
}
export function visibleAtoms(atoms: readonly DocumentAtom[]) { return orderAtoms(atoms).filter(atom => !atom.deleted); }
export function atomText(atoms: readonly DocumentAtom[]) { return visibleAtoms(atoms).map(atom => atom.text).join(""); }
export function textChanges(atoms: readonly DocumentAtom[], changes: readonly TextChange[]): DocumentChange[] {
  const visible = visibleAtoms(atoms);
  const boundaries = [0];
  for (const atom of visible) boundaries.push(boundaries[boundaries.length - 1]! + atom.text.length);
  if (!changes.length || changes.length > 32) throw new Error("Split this edit into smaller changes");
  let previousEnd = -1;
  const result = changes.map(change => {
    const from = boundaries.indexOf(change.from), to = boundaries.indexOf(change.to);
    if (from < 0 || to < from || change.from < previousEnd || (change.insert.includes("\0") || Array.from(change.insert).some(character => { const scalar = character.codePointAt(0)!; return scalar >= 0xd800 && scalar <= 0xdfff; }))) throw new Error("Edit must preserve complete Unicode characters");
    previousEnd = change.to;
    return { after_id: from ? visible[from - 1]!.id : null, delete_ids: visible.slice(from, to).map(atom => atom.id), insert: change.insert };
  });
  if (result.reduce((count, change) => count + Array.from(change.insert).length, 0) > 2_048 || result.reduce((count, change) => count + change.delete_ids.length, 0) > 4_096) throw new Error("Edit up to 2,048 characters at a time");
  return result;
}
export function optimisticApply(atoms: readonly DocumentAtom[], input: DocumentEdit, orderVersion: number): DocumentAtom[] {
  const nodes = new Map(atoms.map(atom => [atom.id, { ...atom }]));
  let offset = 0;
  for (const change of input.changes || []) {
    if (change.after_id !== null && !nodes.has(change.after_id)) throw new Error("Your insertion anchor is no longer available");
    for (const id of change.delete_ids) {
      const atom = nodes.get(id); if (!atom) throw new Error("Your selected text is no longer available");
      atom.deleted = true;
    }
    let anchor = change.after_id;
    for (const text of Array.from(change.insert)) {
      const id = `${input.client_operation_id}:${offset}`;
      // A fresh authorized snapshot can already contain a submitted operation
      // whose HTTP acknowledgement was lost. Never overwrite its server order.
      if (!nodes.has(id)) nodes.set(id, { id, after_id: anchor, text, deleted: false, order: orderVersion * MAX_ATOMS + offset });
      anchor = id; offset++;
    }
  }
  const result = orderAtoms([...nodes.values()]);
  const visible = result.filter(atom => !atom.deleted);
  if (visible.length > 16_000 || new TextEncoder().encode(visible.map(atom => atom.text).join("")).length > 65_536) throw new Error("This document has reached its text limit");
  return result;
}
export function committedApply(document: SharedDocument, operation: DocumentOperation): SharedDocument {
  if (operation.document_id !== document.id || operation.generation !== document.generation) throw new Error("Document generation changed");
  if (operation.version <= document.version) return document;
  if (operation.version !== document.version + 1) throw new Error("Document replay gap");
  const atoms = new Map(document.atoms.map(atom => [atom.id, { ...atom }]));
  for (const atom of operation.inserted_atoms) {
    if (atoms.has(atom.id)) throw new Error("Duplicate committed atom");
    atoms.set(atom.id, { ...atom });
  }
  for (const id of operation.deleted_atom_ids) {
    const atom = atoms.get(id); if (!atom) throw new Error("Missing committed atom");
    atom.deleted = true;
  }
  const ordered = orderAtoms([...atoms.values()]);
  return { ...document, atoms: ordered, content: atomText(ordered), version: operation.version, title: operation.title ?? document.title, updated_at: operation.inserted_at,
    readonly: document.readonly || operation.version >= 4_000 || ordered.length >= MAX_ATOMS };
}
export function selectionIds(atoms: readonly DocumentAtom[], anchor: number, head: number) {
  const visible = visibleAtoms(atoms);
  const at = (position: number) => {
    let offset = 0, id: string | null = null;
    for (const atom of visible) { if (offset + atom.text.length > position) break; offset += atom.text.length; id = atom.id; }
    return id;
  };
  return { anchor_id: at(anchor), head_id: at(head) };
}
export function selectionOffsets(atoms: readonly DocumentAtom[], anchorId: string | null, headId: string | null) {
  const offsets = new Map<string | null, number>([[null, 0]]);
  let offset = 0;
  for (const atom of orderAtoms(atoms)) { if (!atom.deleted) offset += atom.text.length; offsets.set(atom.id, offset); }
  const anchor = offsets.get(anchorId), head = offsets.get(headId);
  return anchor === undefined || head === undefined ? null : { anchor, head };
}
