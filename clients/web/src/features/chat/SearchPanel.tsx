import { useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { Conversation, Message, User } from "../../types";
import { conversationTitle, errorText, formatTime } from "../../lib/format";
import { useModalDialog } from "../../components/useModalDialog";

export function SearchPanel({
  api,
  conversations,
  users,
  onClose,
  onSelect
}: {
  api: ApiClient;
  conversations: Conversation[];
  users: User[];
  onClose: () => void;
  onSelect: (message: Message) => void;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Message[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const usersById = new Map(users.map((user) => [user.id, user]));
  const conversationsById = new Map(conversations.map((conversation) => [conversation.id, conversation]));
  const dialogRef = useModalDialog(onClose);

  async function search(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!query.trim()) return;
    setBusy(true);
    setError(null);
    try {
      setResults(await api.searchMessages(query.trim()));
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="drawer-backdrop">
    <aside ref={dialogRef} className="search-panel" role="dialog" aria-modal="true" aria-labelledby="message-search-title">
      <header><div><span className="eyebrow">Authorized results</span><h2 id="message-search-title">Search messages</h2></div><button className="icon-button" type="button" aria-label="Close search" onClick={onClose}>×</button></header>
      <form className="search-form" role="search" onSubmit={(event) => void search(event)}>
        <label className="sr-only" htmlFor="message-search">Search accessible messages</label>
        <input id="message-search" type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search messages" autoFocus data-initial-focus />
        <button className="button primary compact" type="submit" disabled={busy || !query.trim()}>{busy ? "Searching…" : "Search"}</button>
      </form>
      {error && <div className="form-error" role="alert">{error}</div>}
      {!busy && results.length === 0 && query && <p className="empty-copy">No accessible messages found.</p>}
      <ol className="search-results">
        {results.map((message) => {
          const conversation = conversationsById.get(message.conversation_id);
          return <li key={message.id}><button type="button" onClick={() => onSelect(message)}><span><strong>{conversation ? conversationTitle(conversation) : "Conversation"}</strong><time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time></span><p>{message.body}</p><small>{usersById.get(message.sender_user_id)?.display_name || "Unknown user"}</small></button></li>;
        })}
      </ol>
    </aside>
    </div>
  );
}
