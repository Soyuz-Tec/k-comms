import { act, render } from "@testing-library/react";
import { EditorView } from "@codemirror/view";
import { describe, expect, it, vi } from "vitest";
import type { DocumentEdit } from "../../types/sharedDocuments";
import { atomText, optimisticApply, textChanges } from "./documentModel";
import { SharedDocumentEditor } from "./SharedDocumentEditor";

const originalId = "00000000-0000-4000-8000-000000000001", changedId = "00000000-0000-4000-8000-000000000002";
const input = (id: string, text: string): DocumentEdit => ({ client_operation_id: id, generation: 1, base_version: 1, kind: "edit", changes: [{ after_id: null, insert: text, delete_ids: [] }] });

describe("actual CodeMirror scalar positions", () => {
  it.each(["A\r\nB", "A\rB", "A\nB", "😀\r\néB"])("preserves original CR/LF and Unicode atoms for %j", content => {
    const atoms = optimisticApply([], input(originalId, content), 1);
    const onEdit = vi.fn(), onError = vi.fn();
    const { container } = render(<SharedDocumentEditor content={content} atoms={atoms} readonly={false} peers={[]} onEdit={onEdit} onSelection={() => undefined} onError={onError} />);
    const view = EditorView.findFromDOM(container.querySelector(".cm-content")!)!;
    expect(view.state.doc.toString()).toBe(content);
    const from = content.indexOf("B");
    act(() => view.dispatch({ changes: { from, insert: "\r\n🙂" } }));
    const changes = onEdit.mock.calls[0]![0] as Parameters<typeof textChanges>[1];
    const operation = { ...input(changedId, ""), changes: textChanges(atoms, changes) };
    expect(atomText(optimisticApply(atoms, operation, 2))).toBe(content.slice(0, from) + "\r\n🙂B");
    expect(view.state.doc.toString()).toBe(atomText(optimisticApply(atoms, operation, 2)));
    expect(onError).not.toHaveBeenCalled();
  });
  it("preserves CRLF in server updates without generating a second edit", () => {
    const onEdit = vi.fn(), props = { readonly: false, peers: [], onEdit, onSelection: () => undefined, onError: () => undefined };
    const content = "😀\r\nB", atoms = optimisticApply([], input(originalId, content), 1);
    const { container, rerender } = render(<SharedDocumentEditor {...props} content="" atoms={[]} />);
    rerender(<SharedDocumentEditor {...props} content={content} atoms={atoms} />);
    const view = EditorView.findFromDOM(container.querySelector(".cm-content")!)!;
    expect(view.state.doc.toString()).toBe(content); expect(onEdit).not.toHaveBeenCalled();
    act(() => view.dispatch({ changes: { from: 0, to: 2, insert: "🙂" } }));
    const changes = onEdit.mock.calls[0]![0] as Parameters<typeof textChanges>[1];
    expect(textChanges(atoms, changes)[0]!.delete_ids).toEqual([originalId + ":0"]);
  });
});
