import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import type { WhiteboardMessageReference } from "../../types";
import { AppIcon } from "../../components/AppIcon";
import { DraggableSurface } from "../../components/DraggableSurface";
import { setProtectedSurface } from "../experience/companion-collision";
import {
  useWhiteboardCollaboration,
  type WhiteboardCollaborationOptions
} from "./useWhiteboardCollaboration";
import { KCommsDrawingCanvas } from "./KCommsDrawingCanvas";
import { CanvasControls } from "./CanvasControls";
import "./whiteboard.css";

export function CollaborativeWhiteboard({
  conversationId,
  conversationTitle,
  collaborationOptions,
  clearRequestId = 0,
  focusElementIds = [],
  onMessageReference,
  compact = false,
  statusContainer
}: {
  conversationId: string;
  conversationTitle: string;
  collaborationOptions?: WhiteboardCollaborationOptions;
  clearRequestId?: number;
  focusElementIds?: readonly string[];
  onMessageReference?: (reference: WhiteboardMessageReference) => void;
  compact?: boolean;
  statusContainer?: HTMLElement | null;
}) {
  const [editor, setEditor] = useState<ExcalidrawImperativeAPI | null>(null);
  const collaboration = useWhiteboardCollaboration(
    conversationId,
    collaborationOptions,
    focusElementIds
  );

  /*
   * The canvas tells the call companion it is here, and when it is being drawn
   * on, so the companion can get off the drawable plane.
   *
   * Published rather than detected: the companion renders outside this tree
   * entirely, and a querySelector for ".whiteboard-room" would invent a second
   * source of truth for something this component already knows.
   *
   * Above the early returns for loading and load errors on purpose: an
   * effect below them runs on some renders and not others, which React
   * rejects outright as "rendered more hooks than during the previous
   * render".
   */
  useEffect(() => {
    setProtectedSurface("canvasVisible", true);
    return () => {
      setProtectedSurface("canvasVisible", false);
      setProtectedSurface("canvasEditing", false);
    };
  }, []);

  if (collaboration.initialElements === null) {
    if (collaboration.historyError) {
      return (
        <section className="whiteboard-loading whiteboard-load-error" role="alert">
          <AppIcon name="triangleAlert" />
          <h2>We couldn’t restore this whiteboard</h2>
          {/*
            * The raw reason was the whole message, so a failure could greet a
            * user with "Spread syntax requires ...iterable[Symbol.iterator] to
            * be a function". Say what happened and what to do, and keep the
            * technical string beneath it for a support conversation -- the same
            * shape the Files error already uses.
            */}
          <p>Its history could not be loaded, so nothing has been changed. Try again, and if it keeps failing the detail below will help support.</p>
          <p className="whiteboard-load-error-detail">{collaboration.historyError}</p>
          <button
            className="button primary"
            type="button"
            onClick={collaboration.retryHistory}
          >
            Try again
          </button>
        </section>
      );
    }
    return (
      <section className="whiteboard-loading" aria-busy="true">
        <span className="spinner" aria-hidden="true" />
        <p>Restoring durable board history…</p>
      </section>
    );
  }

  const statusbar = (
    <div className="whiteboard-statusbar" role="status">
      <span
        className={`connection-dot ${collaboration.connectionStatus}`}
        aria-hidden="true"
      />
      <strong>
        {collaboration.connectionStatus === "live"
          ? "Live canvas"
          : collaboration.connectionStatus === "offline"
            ? "Offline editing"
            : "Reconnecting"}
      </strong>
      <span>{collaboration.collaboratorCount + 1} active</span>
      <span>
        {collaboration.elementCount} {collaboration.elementCount === 1 ? "object" : "objects"}
      </span>
      <span
        className={`whiteboard-sync-status ${collaboration.saveStatus}`}
        title={
          collaboration.pendingCount > 0
            ? `${collaboration.pendingCount} unsynced operation${collaboration.pendingCount === 1 ? "" : "s"}`
            : "All changes are synchronized"
        }
      >
        {collaboration.saveStatus === "synced"
          ? "Synced"
          : collaboration.saveStatus === "syncing"
            ? "Syncing…"
            : collaboration.saveStatus === "unsynced"
              ? `Unsynced changes${collaboration.pendingCount > 0 ? ` · ${collaboration.pendingCount} pending` : ""}`
              : "Sync paused"}
      </span>
    </div>
  );

  return (
    <section
      className={`whiteboard-room${compact ? " whiteboard-room-compact" : ""}`}
      /*
       * Pen and stylus only. A mouse or finger drawing still moves the
       * pointer, but the contract names pen input specifically, and treating
       * every pointer press as editing would keep the companion pinned for
       * anyone who clicks the canvas once.
       */
      onPointerDown={(event) => {
        if (event.pointerType === "pen") setProtectedSurface("canvasEditing", true);
      }}
      onPointerUp={(event) => {
        if (event.pointerType === "pen") setProtectedSurface("canvasEditing", false);
      }}
      onPointerCancel={() => setProtectedSurface("canvasEditing", false)}
      /*
       * Excalidraw's text editor is a real textarea inside this subtree, so
       * focus landing on any editable element is the signal. onFocus/onBlur
       * bubble in React, which is what makes this reachable from here at all.
       */
      onFocus={(event) => {
        if (isTextEntry(event.target)) setProtectedSurface("canvasEditing", true);
      }}
      onBlur={(event) => {
        if (isTextEntry(event.target)) setProtectedSurface("canvasEditing", false);
      }}
      aria-label={`Whiteboard for ${conversationTitle}`}
    >
      {/*
        The canvas is invisible to assistive technology: its contents are pixels,
        not DOM, so a screen reader is handed an empty region no matter how well
        the surrounding controls are labelled. This mirrors the scene as real
        elements. It is not decoration, and it must not be removed to tidy the
        markup.
      */}
      <section className="visually-hidden" aria-live="polite">
        {/*
          Deliberately "Canvas" rather than "Whiteboard": the page already has a
          "Whiteboard" heading, and accessible-name matching is substring-based,
          so a second heading containing that word makes every by-role lookup
          ambiguous for assistive technology and for tests alike.
        */}
        <h2>{`Canvas contents, ${collaboration.sceneSummary.length} object${collaboration.sceneSummary.length === 1 ? "" : "s"}`}</h2>
        {collaboration.sceneSummary.length > 0 && (
          <ul>
            {collaboration.sceneSummary.map((object) => (
              <li key={object.id}>{object.label}</li>
            ))}
          </ul>
        )}
      </section>
      {compact ? (
        <DraggableSurface
          className="whiteboard-floating-status"
          dragLabel="canvas status"
        >
          {statusbar}
        </DraggableSurface>
      ) : statusContainer ? createPortal(statusbar, statusContainer) : statusbar}

      {collaboration.error && (
        <div className="whiteboard-error" role="alert">
          {collaboration.error}
        </div>
      )}

      {collaboration.focusStatus === "missing" && (
        <div className="whiteboard-reference-status" role="status">
          The referenced whiteboard object is no longer available.
        </div>
      )}
      {collaboration.focusStatus === "partial" && (
        <div className="whiteboard-reference-status" role="status">
          Some referenced whiteboard objects are no longer available.
        </div>
      )}

      <div
        className="whiteboard-canvas"
        data-testid="whiteboard-canvas"
        onKeyDownCapture={collaboration.armLocalChanges}
        onPointerDownCapture={collaboration.armLocalChanges}
      >
        <KCommsDrawingCanvas
          initialData={{
            elements: collaboration.initialElements,
            appState: { name: `${conversationTitle} whiteboard` }
          }}
          excalidrawAPI={(nextEditor) => {
            setEditor(nextEditor);
            collaboration.attachEditor(nextEditor);
          }}
          isCollaborating
          onChange={collaboration.handleEditorChange}
          onPointerUpdate={collaboration.sendPointerUpdate}
          onLinkOpen={(_element, event) => event.preventDefault()}
          validateEmbeddable={false}
        />
        <CanvasControls
          clearRequestId={clearRequestId}
          editor={editor}
          elementCount={collaboration.elementCount}
          onClearCanvas={collaboration.clearBoard}
          onMessageSelection={onMessageReference ? () => {
            const reference = collaboration.messageReference();
            if (reference) onMessageReference(reference);
          } : undefined}
          selectedCount={collaboration.selectedElementIds.length}
          shared
        />
      </div>
    </section>
  );
}

/**
 * Whether focus landed somewhere text is entered.
 *
 * Excalidraw's text editor is a textarea it creates and destroys on demand, so
 * there is no stable element to watch -- only the shape of whatever currently
 * has focus.
 */
function isTextEntry(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  return target.tagName === "TEXTAREA" || target.tagName === "INPUT";
}
