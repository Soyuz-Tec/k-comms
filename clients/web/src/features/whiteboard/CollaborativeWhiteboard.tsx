import { useState } from "react";
import type { WhiteboardMessageReference } from "../../types";
import { AppIcon } from "../../components/AppIcon";
import {
  useWhiteboardCollaboration,
  type WhiteboardCollaborationOptions
} from "./useWhiteboardCollaboration";
import { KCommsDrawingCanvas } from "./KCommsDrawingCanvas";
import "./whiteboard.css";

export function CollaborativeWhiteboard({
  conversationId,
  conversationTitle,
  collaborationOptions,
  focusElementIds = [],
  onMessageReference,
  compact = false
}: {
  conversationId: string;
  conversationTitle: string;
  collaborationOptions?: WhiteboardCollaborationOptions;
  focusElementIds?: readonly string[];
  onMessageReference?: (reference: WhiteboardMessageReference) => void;
  compact?: boolean;
}) {
  const [confirmClear, setConfirmClear] = useState(false);
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
        {onMessageReference && <button
          className="button ghost compact"
          type="button"
          disabled={collaboration.selectedElementIds.length === 0}
          onClick={() => {
            const reference = collaboration.messageReference();
            if (reference) onMessageReference(reference);
          }}
        >
          <AppIcon name="message" /> Message selection
        </button>}
        <button
          className="button ghost compact"
          type="button"
          onClick={() => setConfirmClear(true)}
        >
          <AppIcon name="trash" /> Clear board
        </button>
      </div>

      {collaboration.error && (
        <div className="whiteboard-error" role="alert">
          {collaboration.error}
        </div>
      )}

      {confirmClear && (
        <div
          className="whiteboard-confirm"
          role="alertdialog"
          aria-modal="true"
          aria-labelledby="whiteboard-clear-title"
        >
          <h2 id="whiteboard-clear-title">Clear this shared whiteboard?</h2>
          <p>
            Everyone in this room will see a blank board. Earlier operations
            remain in the durable board history.
          </p>
          <div>
            <button
              className="button ghost"
              type="button"
              onClick={() => setConfirmClear(false)}
            >
              Cancel
            </button>
            <button
              className="button danger"
              type="button"
              onClick={() => {
                setConfirmClear(false);
                void collaboration.clearBoard();
              }}
            >
              Clear for everyone
            </button>
          </div>
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
          excalidrawAPI={collaboration.attachEditor}
          isCollaborating
          onChange={collaboration.handleEditorChange}
          onPointerUpdate={collaboration.sendPointerUpdate}
          onLinkOpen={(_element, event) => event.preventDefault()}
          validateEmbeddable={false}
        />
      </div>
    </section>
  );
}
