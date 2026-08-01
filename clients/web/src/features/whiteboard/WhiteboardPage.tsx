import { Excalidraw } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import { useState } from "react";
import { useSearchParams } from "react-router";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import { useWhiteboardCollaboration } from "./useWhiteboardCollaboration";
import "./whiteboard.css";

export function WhiteboardPage() {
  const { conversations, loading } = useWorkspaceData();
  const [searchParams, setSearchParams] = useSearchParams();
  const requested = searchParams.get("conversation");
  const activeConversation =
    conversations.find((conversation) => conversation.id === requested) ??
    conversations[0] ??
    null;

  if (loading) {
    return (
      <main className="centered-page" id="main-content" aria-busy="true">
        <div className="loading-card">
          <span className="spinner" aria-hidden="true" />
          <p>Opening whiteboard…</p>
        </div>
      </main>
    );
  }

  return (
    <main className="whiteboard-page" id="main-content">
      <header className="whiteboard-heading">
        <div>
          <span className="eyebrow">Unified collaboration</span>
          <h1>Whiteboard</h1>
          <p>Sketch, diagram, and plan together in the selected conversation.</p>
        </div>
        <label>
          <span>Conversation</span>
          <select
            value={activeConversation?.id ?? ""}
            disabled={conversations.length === 0}
            onChange={(event) => {
              const next = new URLSearchParams(searchParams);
              next.set("conversation", event.target.value);
              setSearchParams(next);
            }}
          >
            {conversations.map((conversation) => (
              <option key={conversation.id} value={conversation.id}>
                {conversation.title || "Untitled conversation"}
              </option>
            ))}
          </select>
        </label>
      </header>

      {activeConversation ? (
        <WhiteboardRoom
          key={activeConversation.id}
          conversationId={activeConversation.id}
          conversationTitle={activeConversation.title || "Untitled conversation"}
        />
      ) : (
        <section className="empty-state whiteboard-empty">
          <AppIcon name="messages" />
          <h2>Create or join a conversation first</h2>
          <p>Every whiteboard is private to one conversation and its current members.</p>
        </section>
      )}
    </main>
  );
}

function WhiteboardRoom({
  conversationId,
  conversationTitle
}: {
  conversationId: string;
  conversationTitle: string;
}) {
  const [confirmClear, setConfirmClear] = useState(false);
  const collaboration = useWhiteboardCollaboration(conversationId);

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
      className="whiteboard-room"
      aria-label={`Whiteboard for ${conversationTitle}`}
    >
      <div className="whiteboard-statusbar" role="status">
        <span
          className={`connection-dot ${collaboration.connectionStatus}`}
          aria-hidden="true"
        />
        <strong>
          {collaboration.connectionStatus === "live"
            ? "Live collaboration"
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
            ? "All changes saved"
            : collaboration.saveStatus === "saving"
              ? "Saving…"
              : "Save needs attention"}
        </span>
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
            Everyone in this conversation will see a blank board. Earlier operations
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
