import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { ChangeEvent } from "react";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { convertToExcalidrawElements } from "@excalidraw/excalidraw";
import { ConfirmDialog } from "../../components/ActionDialog";
import { AppIcon } from "../../components/AppIcon";
import { useOptionalWorkspaceData } from "../../app/workspace-data";
import { useSession } from "../../app/session";
import { clientMessageId, errorText } from "../../lib/format";
import { sha256, uploadToPresignedTarget } from "../../api";
import type { BoardVersion } from "../../types/rich-content";
import { loadBoardAssetFile } from "./boardAssetFiles";

export function BoardLibraryControls({ editor, conversationId, synchronized, onRestore, onArmChanges, triggerContainer }: {
  editor: ExcalidrawImperativeAPI | null; conversationId: string; synchronized: boolean;
  onRestore: () => void; onArmChanges: () => void;
  triggerContainer?: HTMLElement | null;
}) {
  const { api, session } = useSession();
  const workspace = useOptionalWorkspaceData();
  const role = workspace?.conversations.find(c => c.id === conversationId)?.membership_role;
  const canManage = role === "owner" || role === "moderator";
  const [open, setOpen] = useState(false);
  const [versions, setVersions] = useState<BoardVersion[]>([]);
  const [restoreTarget, setRestoreTarget] = useState<BoardVersion | null>(null);
  const [title, setTitle] = useState("");
  const [libraryVersion, setLibraryVersion] = useState(1);
  const [label, setLabel] = useState("");
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  useEffect(() => {
    if (!editor || !session || typeof api.boardAsset !== "function") return;
    const controller = new AbortController(); abortRef.current = controller;
    const pending = new Set<string>();
    const loadImages = () => {
      for (const element of editor.getSceneElements()) {
        if (element.type !== "image" || !element.fileId || element.isDeleted || editor.getFiles()[element.fileId] || pending.has(element.fileId)) continue;
        pending.add(element.fileId);
        void loadBoardAssetFile(api, conversationId, element.fileId, controller.signal).then(file => {
          if (!controller.signal.aborted) editor.addFiles([file]);
        }).catch(reason => { if (!controller.signal.aborted) setError(errorText(reason)); });
      }
    };
    loadImages();
    const remove = editor.onChange(loadImages);
    return () => { controller.abort(); remove(); };
  }, [api, conversationId, editor, session?.user.id]);

  async function refresh() { setError(""); try {
    const [rows, scene] = await Promise.all([api.boardVersions(conversationId), api.exportBoard(conversationId)]);
    setVersions(rows); setTitle(scene.title); setLibraryVersion(scene.library_version);
  } catch (e) { setError(errorText(e)); } }
  async function rename() {
    if (busy || !canManage || !title.trim()) return;
    setBusy(true); setError("");
    try { const board = await api.renameBoard(conversationId, title.trim(), libraryVersion); setLibraryVersion(board.library_version); setStatus("Board name updated."); }
    catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  }
  async function checkpoint() {
    if (!synchronized || busy || !label.trim()) return;
    setBusy(true); setError("");
    try { const scene = await api.exportBoard(conversationId); await api.checkpointBoard(conversationId, label.trim(), scene.through_sequence); setLabel(""); setStatus("Board checkpoint saved."); await refresh(); }
    catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  }
  async function restore(version: BoardVersion) {
    if (!synchronized || busy) return;
    setBusy(true); setError("");
    try { const scene = await api.exportBoard(conversationId); await api.restoreBoard(conversationId, version.id, scene.through_sequence); setStatus("Checkpoint restored."); setRestoreTarget(null); onRestore(); }
    catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  }
  async function exportScene() {
    if (!synchronized || busy) return;
    setBusy(true); setError("");
    try {
      const scene = await api.exportBoard(conversationId);
      const files = {} as Record<string, Awaited<ReturnType<typeof loadBoardAssetFile>>>;
      const referenced = new Set(scene.elements.filter(element => element.type === "image" && !element.isDeleted).map(element => element.fileId));
      for (const asset of scene.assets) if (referenced.has(asset.id)) files[asset.id] = await loadBoardAssetFile(api, conversationId, asset.id, abortRef.current?.signal);
      const blob = new Blob([JSON.stringify({ ...scene, assets: undefined, files })], { type: "application/json" });
      const url = URL.createObjectURL(blob); const anchor = document.createElement("a"); anchor.href = url; anchor.download = "k-comms-board.excalidraw"; anchor.click(); window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
      setStatus("Approved board scene exported.");
    } catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  }
  async function addImage(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]; event.target.value = "";
    if (!file || !editor || busy) return;
    if (!["image/png", "image/jpeg", "image/webp", "image/gif"].includes(file.type) || file.size > 10_485_760) { setError("Choose a PNG, JPEG, WebP or GIF image up to 10 MB."); return; }
    setBusy(true); setError(""); let attachmentId: string | null = null; let shared = false;
    try {
      const intent = await api.createAttachment(file, await sha256(file)); attachmentId = intent.data.id;
      await uploadToPresignedTarget(intent.upload, file, abortRef.current?.signal);
      let attachment = await api.completeAttachment(intent.data.id);
      for (let i = 0; i < 45 && attachment.status !== "ready"; i += 1) {
        if (["quarantined", "scan_failed", "deleted"].includes(attachment.status)) throw new Error("This image did not pass its safety scan.");
        setStatus("Checking image safety…"); await new Promise(resolve => window.setTimeout(resolve, 1_000));
        if (abortRef.current?.signal.aborted) return;
        attachment = (await api.attachmentStatus(attachment.id)).data;
      }
      if (attachment.status !== "ready") throw new Error("The safety scan is still pending. Retry after it finishes.");
      await api.sendMessage(conversationId, { client_message_id: clientMessageId(), body: `Board image: ${file.name}`, attachment_ids: [attachment.id] }); shared = true;
      const asset = await api.addBoardAsset(conversationId, attachment.id);
      const approved = await loadBoardAssetFile(api, conversationId, asset.id, abortRef.current?.signal);
      if (abortRef.current?.signal.aborted) return;
      editor.addFiles([approved]);
      const image = new Image(); image.src = approved.dataURL; await image.decode();
      const ratio = Math.min(1, 800 / Math.max(image.naturalWidth, image.naturalHeight));
      const app = editor.getAppState();
      const elements = convertToExcalidrawElements([{ type: "image", fileId: approved.id, x: -app.scrollX + 50, y: -app.scrollY + 50,
        width: image.naturalWidth * ratio, height: image.naturalHeight * ratio, status: "saved" }]);
      onArmChanges(); editor.updateScene({ elements: [...editor.getSceneElements(), ...elements] }); setStatus("Image shared with the conversation and added to the board.");
    } catch (e) { setError(errorText(e)); }
    finally { if (attachmentId && !shared) void api.abandonAttachment(attachmentId).catch(() => undefined); setBusy(false); }
  }
  if (!session || typeof api.exportBoard !== "function") return null;
  const trigger = <button className="button ghost compact board-history-trigger" type="button" aria-label="Board history & assets" title="Board history & assets" aria-expanded={open} onClick={() => { setOpen(v => !v); if (!open) void refresh(); }}><AppIcon name="clock" /><span>Board history &amp; assets</span></button>;
  return <>
    {triggerContainer && createPortal(trigger, triggerContainer)}
    {(!triggerContainer || open || restoreTarget) && <div className="board-library-controls">
    {!triggerContainer && trigger}
    {open && <section className="board-library" aria-label="Board history and assets" aria-busy={busy}>
      <h2>Board history</h2>
      {error && <p role="alert">{error}</p>}{status && <p role="status">{status}</p>}
      {canManage && <><label>Board name<input maxLength={160} value={title} onChange={e => setTitle(e.target.value)} /></label><button type="button" disabled={busy || !title.trim()} onClick={() => void rename()}>Rename board</button></>}
      <label>Checkpoint name<input maxLength={160} value={label} onChange={e => setLabel(e.target.value)} /></label>
      <button type="button" disabled={!synchronized || busy || !label.trim()} onClick={() => void checkpoint()}>Save checkpoint</button>
      {!synchronized && <p>Wait for board changes to synchronize before saving, restoring or exporting.</p>}
      <ul>{versions.map(version => <li key={version.id}><span>{version.label} · Revision {version.through_sequence}</span>{canManage && <button type="button" disabled={!synchronized || busy} onClick={() => setRestoreTarget(version)}>Restore {version.label}</button>}</li>)}</ul>
      <button type="button" disabled={!synchronized || busy} onClick={() => void exportScene()}>Export board scene</button>
      <label>Add image to board and conversation<input type="file" accept="image/png,image/jpeg,image/webp,image/gif" disabled={!editor || busy} onChange={e => void addImage(e)} /></label>
      <p>Board images follow the source message’s access, safety and retention rules.</p>
    </section>}
    {restoreTarget && <ConfirmDialog title={`Restore ${restoreTarget.label}?`} description="This replaces the current shared scene with the selected checkpoint." impact="All conversation members see the restored scene. The operation history is retained." confirmLabel="Restore checkpoint" busy={busy} error={error} onCancel={() => { if (!busy) setRestoreTarget(null); }} onConfirm={() => void restore(restoreTarget)} />}
  </div>}
  </>;
}
