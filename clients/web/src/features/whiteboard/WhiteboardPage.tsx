import { useMemo, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import { conversationTitle } from "../../lib/format";
import { useSession } from "../../app/session";
import { BoardGallery } from "./BoardGallery";
import "./board-library.css";
import { CollaborativeWhiteboard } from "./CollaborativeWhiteboard";

export function WhiteboardPage() {
  const { api } = useSession();
  const [galleryOpen, setGalleryOpen] = useState(false);
  const [statusContainer, setStatusContainer] = useState<HTMLDivElement | null>(null);
  const [libraryTriggerContainer, setLibraryTriggerContainer] = useState<HTMLDivElement | null>(null);
  const { conversations, loading } = useWorkspaceData();
  const conversationTitles = useMemo(() => new Map(conversations.map(conversation => [conversation.id, conversationTitle(conversation)])), [conversations]);
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const requested = searchParams.get("conversation");
  const focusElementIds = (searchParams.get("focus_elements") || "")
    .split(",")
    .filter((id) => id.length >= 8 && id.length <= 128)
    .slice(0, 20);
  const activeConversation =
    requested === null ? conversations[0] ?? null :
      conversations.find((conversation) => conversation.id === requested) ?? null;

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
    <main className={`whiteboard-page${galleryOpen ? " gallery-open" : ""}`} id="main-content">
      <header className="whiteboard-heading">
        <Link className="surface-back whiteboard-content-link" to="/app/content" aria-label="Content" title="Content"><AppIcon name="arrowLeft" /><span>Content</span></Link>
        <div className="whiteboard-heading-copy">
          <div className="whiteboard-heading-title"><h1>Whiteboard</h1><p title={activeConversation ? conversationTitle(activeConversation) : undefined}>{activeConversation ? conversationTitle(activeConversation) : "Choose a conversation"}</p></div>
        </div>
        <div ref={setStatusContainer} className="whiteboard-heading-status" />
        <div ref={setLibraryTriggerContainer} className="whiteboard-context-actions">
        <button type="button" className="button ghost" aria-label="Board gallery" title="Board gallery" aria-expanded={galleryOpen} aria-controls="whiteboard-gallery" onClick={() => setGalleryOpen(value => !value)}><AppIcon name="whiteboard" /><span>Board gallery</span></button>
        <label>
          <span>Conversation</span>
          <select
            value={activeConversation?.id ?? ""}
            disabled={conversations.length === 0}
            onChange={(event) => {
              const next = new URLSearchParams(searchParams);
              next.set("conversation", event.target.value);
              next.delete("focus_elements");
              setSearchParams(next);
            }}
          >
            {!activeConversation && <option value="" disabled>Choose a conversation</option>}
            {conversations.map((conversation) => (
              <option key={conversation.id} value={conversation.id}>
                {conversation.title || "Untitled conversation"}
              </option>
            ))}
          </select>
        </label>
        {activeConversation && <Link className="button ghost" aria-label="Open conversation" title="Open conversation" to={`/app/?conversation=${encodeURIComponent(activeConversation.id)}`}>
          <AppIcon name="message" /><span>Chat</span>
        </Link>}
        </div>
      </header>

      {galleryOpen && <BoardGallery api={api} conversationTitles={conversationTitles} onOpen={id => {
        setSearchParams({ conversation: id }); setGalleryOpen(false);
      }} />}
      {activeConversation ? (
        <CollaborativeWhiteboard
          key={activeConversation.id}
          conversationId={activeConversation.id}
          conversationTitle={activeConversation.title || "Untitled conversation"}
          statusContainer={statusContainer}
          libraryTriggerContainer={libraryTriggerContainer}
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
        <section className="empty-state whiteboard-empty" role={requested !== null ? "alert" : undefined}>
          <AppIcon name="messages" />
          <h2>{requested !== null ? "Board unavailable" : "Create or join a conversation first"}</h2>
          <p>{requested !== null ? "This conversation is unavailable or your access has changed. Choose another conversation above or return to Inbox." : "Every whiteboard is private to one conversation and its current members."}</p>
          <Link className="button primary" to="/app/">Open Inbox</Link>
        </section>
      )}
    </main>
  );
}
