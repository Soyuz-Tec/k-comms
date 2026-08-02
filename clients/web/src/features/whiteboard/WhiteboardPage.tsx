import { useSearchParams } from "react-router";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import { CollaborativeWhiteboard } from "./CollaborativeWhiteboard";

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
        <CollaborativeWhiteboard
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
