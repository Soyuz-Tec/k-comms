import { Link, useNavigate, useSearchParams } from "react-router";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import { CollaborativeWhiteboard } from "./CollaborativeWhiteboard";

export function WhiteboardPage() {
  const { conversations, loading } = useWorkspaceData();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const requested = searchParams.get("conversation");
  const focusElementIds = (searchParams.get("focus_elements") || "")
    .split(",")
    .filter((id) => id.length >= 8 && id.length <= 128)
    .slice(0, 20);
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
        <div className="whiteboard-heading-copy">
          <h1>Whiteboard</h1>
          <p>Sketch, diagram, and plan together in the selected conversation.</p>
        </div>
        <div className="whiteboard-context-actions">
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
        {activeConversation && <Link className="button ghost" aria-label="Open conversation" title="Open conversation" to={`/app/?conversation=${encodeURIComponent(activeConversation.id)}`}>
          <AppIcon name="message" /><span>Open conversation</span>
        </Link>}
        </div>
      </header>

      {activeConversation ? (
        <CollaborativeWhiteboard
          key={activeConversation.id}
          conversationId={activeConversation.id}
          conversationTitle={activeConversation.title || "Untitled conversation"}
          focusElementIds={focusElementIds}
          onMessageReference={(reference) => {
            const params = new URLSearchParams({
              conversation: activeConversation.id,
              whiteboard_elements: reference.element_ids.join(","),
              whiteboard_sequence: String(reference.board_sequence),
              whiteboard_label: reference.label || "Whiteboard selection"
            });
            navigate(`/app/?${params.toString()}`);
          }}
        />
      ) : (
        <section className="empty-state whiteboard-empty">
          <AppIcon name="messages" />
          <h2>Create or join a conversation first</h2>
          <p>Every whiteboard is private to one conversation and its current members.</p>
          <Link className="button primary" to="/app/">Open Inbox</Link>
        </section>
      )}
    </main>
  );
}
