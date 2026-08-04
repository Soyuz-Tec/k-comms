import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { useState } from "react";
import type { WhiteboardMessageReference } from "../../types";
import { AppIcon } from "../../components/AppIcon";
import { DraggableSurface } from "../../components/DraggableSurface";
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
  compact = false
}: {
  conversationId: string;
  conversationTitle: string;
  collaborationOptions?: WhiteboardCollaborationOptions;
  clearRequestId?: number;
  focusElementIds?: readonly string[];
  onMessageReference?: (reference: WhiteboardMessageReference) => void;
  compact?: boolean;
}) {
  const [editor, setEditor] = useState<ExcalidrawImperativeAPI | null>(null);
  const collaboration = useWhiteboardCollaboration(
    conversationId,
    collaborationOptions,
    focusElementIds
  );

  if (collaboration.initialElements === null) {
    if (collaboration.historyError) {
      return (
        <section className="whiteboard-loading whiteboard-load-error" role="alert">
          <AppIcon name="triangleAlert" />
          <h2>We couldn’t restore this whiteboard</h2>
          <p>{collaboration.historyError}</p>
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
      <span>
        {collaboration.saveStatus === "saved"
          ? "Saved"
          : collaboration.saveStatus === "saving"
            ? "Saving…"
            : "Save needs attention"}
      </span>
    </div>
  );

  return (
    <section
      className={`whiteboard-room${compact ? " whiteboard-room-compact" : ""}`}
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
      ) : statusbar}

      {collaboration.error && (
        <div className="whiteboard-error" role="alert">
          {collaboration.error}
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
