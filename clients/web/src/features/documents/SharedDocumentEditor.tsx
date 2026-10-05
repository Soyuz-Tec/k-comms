import { useEffect, useRef } from "react";
import { Annotation, Compartment, EditorState } from "@codemirror/state";
import { Decoration, EditorView, keymap, type DecorationSet } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import type { DocumentAtom, DocumentPresence } from "../../types/sharedDocuments";
import { selectionOffsets, type TextChange } from "./documentModel";
const serverUpdate = Annotation.define<boolean>();

export function SharedDocumentEditor({ content, atoms, readonly, peers, onEdit, onSelection, onError }: {
  content: string; atoms: DocumentAtom[]; readonly: boolean; peers: DocumentPresence[];
  onEdit: (changes: TextChange[]) => void; onSelection: (anchor: number, head: number) => void; onError: (message: string) => void;
}) {
  const host = useRef<HTMLDivElement>(null);
  const editor = useRef<EditorView | null>(null);
  const callbacks = useRef({ onEdit, onSelection, onError });
  const readOnly = useRef(new Compartment());
  const collaboratorSelection = useRef(new Compartment());
  useEffect(() => { callbacks.current = { onEdit, onSelection, onError }; }, [onEdit, onSelection, onError]);
  useEffect(() => {
    if (!host.current) return;
    const view = new EditorView({ parent: host.current, state: EditorState.create({ doc: content, extensions: [
      markdown(), history(), keymap.of([...defaultKeymap, ...historyKeymap]), EditorView.lineWrapping,
      EditorView.contentAttributes.of({ "aria-label": "Shared document content", spellcheck: "true" }),
      readOnly.current.of(EditorState.readOnly.of(readonly)),
      collaboratorSelection.current.of(EditorView.decorations.of(Decoration.none)),
      EditorView.updateListener.of(update => {
        if (update.docChanged && !update.transactions.some(transaction => transaction.annotation(serverUpdate))) {
          const changes: TextChange[] = [];
          update.changes.iterChanges((from, to, _fromB, _toB, insert) => changes.push({ from, to, insert: insert.toString() }));
          try { callbacks.current.onEdit(changes); }
          catch (failure) {
            callbacks.current.onError(failure instanceof Error ? failure.message : "This edit is too large");
            queueMicrotask(() => { if (editor.current === view) view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: update.startState.doc.toString() }, annotations: serverUpdate.of(true) }); });
          }
        }
        if (update.selectionSet && !update.transactions.some(transaction => transaction.annotation(serverUpdate))) {
          callbacks.current.onSelection(update.state.selection.main.anchor, update.state.selection.main.head);
        }
      })
    ] }) });
    editor.current = view;
    return () => { editor.current = null; view.destroy(); };
    // The editor is stable across server updates; selection/history map through
    // the minimal update below instead of remounting on every peer keystroke.
  }, []);
  useEffect(() => {
    const view = editor.current;
    if (!view || view.state.doc.toString() === content) return;
    const previous = Array.from(view.state.doc.toString()), next = Array.from(content);
    let prefix = 0, suffix = 0;
    while (prefix < previous.length && prefix < next.length && previous[prefix] === next[prefix]) prefix++;
    while (suffix < previous.length - prefix && suffix < next.length - prefix && previous[previous.length - suffix - 1] === next[next.length - suffix - 1]) suffix++;
    const from = previous.slice(0, prefix).join("").length;
    const to = previous.slice(0, previous.length - suffix).join("").length;
    view.dispatch({ changes: { from, to, insert: next.slice(prefix, next.length - suffix).join("") }, annotations: serverUpdate.of(true) });
  }, [content]);
  useEffect(() => { editor.current?.dispatch({ effects: readOnly.current.reconfigure(EditorState.readOnly.of(readonly)) }); }, [readonly]);
  useEffect(() => {
    const ranges = peers.flatMap(peer => {
      const selection = selectionOffsets(atoms, peer.anchor_id, peer.head_id);
      if (!selection || selection.anchor === selection.head) return [];
      return [Decoration.mark({ class: "document-peer-selection" }).range(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head))];
    });
    const decorations: DecorationSet = Decoration.set(ranges, true);
    editor.current?.dispatch({ effects: collaboratorSelection.current.reconfigure(EditorView.decorations.of(decorations)) });
  }, [peers, atoms]);
  return <div className="shared-document-editor" ref={host} />;
}
