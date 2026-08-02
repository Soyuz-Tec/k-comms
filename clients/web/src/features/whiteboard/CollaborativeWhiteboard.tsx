import { Excalidraw } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import { useState } from "react";
import type { WhiteboardMessageReference } from "../../types";
import { AppIcon } from "../../components/AppIcon";
import {
  useWhiteboardCollaboration,
  type WhiteboardCollaborationOptions
} from "./useWhiteboardCollaboration";
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
        <Excalidraw
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
          UIOptions={{
            canvasActions: {
              loadScene: false,
              saveToActiveFile: false
            },
            tools: { image: false }
          }}
        />
      </div>
    </section>
  );
}
