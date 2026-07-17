import { useMemo, useRef, useState } from "react";
import type { FormEvent, KeyboardEvent as ReactKeyboardEvent } from "react";
import type { ApiClient } from "../../api";
import type { Conversation, Message, User } from "../../types";
import { conversationTitle, errorText, formatTime } from "../../lib/format";
import { useModalDialog } from "../../components/useModalDialog";

type DateScope = "any" | "day" | "week" | "month";

const DATE_WINDOWS: Record<Exclude<DateScope, "any">, number> = {
  day: 24 * 60 * 60 * 1_000,
  week: 7 * 24 * 60 * 60 * 1_000,
  month: 30 * 24 * 60 * 60 * 1_000
};

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
  const [conversationId, setConversationId] = useState("all");
  const [senderId, setSenderId] = useState("all");
  const [dateScope, setDateScope] = useState<DateScope>("any");
  const [cursor, setCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [hasSearched, setHasSearched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const conversationsById = useMemo(
    () => new Map(conversations.map((conversation) => [conversation.id, conversation])),
    [conversations]
  );
  const resultButtons = useRef<Array<HTMLButtonElement | null>>([]);
  const requestId = useRef(0);
  const submittedAfter = useRef<string | undefined>(undefined);
  const dialogRef = useModalDialog(onClose);

  async function search(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await loadResults(null, false);
  }

  async function loadResults(nextCursor: string | null, append: boolean) {
    if (!query.trim()) return;
    const currentRequest = ++requestId.current;
    const after = append
      ? submittedAfter.current
      : dateScope === "any"
        ? undefined
        : new Date(Date.now() - DATE_WINDOWS[dateScope]).toISOString();
    if (!append) submittedAfter.current = after;
    setBusy(true);
    setError(null);
    try {
      const response = await api.searchMessagePage(query.trim(), {
        limit: 25,
        cursor: nextCursor,
        conversation_id: conversationId === "all" ? undefined : conversationId,
        sender_user_id: senderId === "all" ? undefined : senderId,
        after
      });
      if (currentRequest !== requestId.current) return;
      setResults((current) => append ? [...current, ...response.data] : response.data);
      setCursor(response.page.next_cursor);
      setHasMore(response.page.has_more);
      setHasSearched(true);
    } catch (reason: unknown) {
      if (currentRequest !== requestId.current) return;
      if (!append) {
        setResults([]);
        setCursor(null);
        setHasMore(false);
        setHasSearched(false);
      }
      setError(errorText(reason));
    } finally {
      if (currentRequest === requestId.current) setBusy(false);
    }
  }

  function queryChanged(value: string) {
    setQuery(value);
    resetResults();
  }

  function resetResults() {
    requestId.current += 1;
    setResults([]);
    setCursor(null);
    setHasMore(false);
    submittedAfter.current = undefined;
    setHasSearched(false);
    setBusy(false);
    setError(null);
  }

  function moveResultFocus(event: ReactKeyboardEvent<HTMLButtonElement>, index: number) {
    let nextIndex: number | null = null;
    if (event.key === "ArrowDown") nextIndex = Math.min(index + 1, results.length - 1);
    if (event.key === "ArrowUp") nextIndex = Math.max(index - 1, 0);
    if (event.key === "Home") nextIndex = 0;
    if (event.key === "End") nextIndex = results.length - 1;
    if (nextIndex === null) return;
    event.preventDefault();
    resultButtons.current[nextIndex]?.focus();
  }

  return (
    <div className="drawer-backdrop">
      <aside ref={dialogRef} className="search-panel" role="dialog" aria-modal="true" aria-labelledby="message-search-title">
        <header><div><span className="eyebrow">Authorized results</span><h2 id="message-search-title">Search messages</h2></div><button className="icon-button" type="button" aria-label="Close search" onClick={onClose}>×</button></header>
        <form className="search-form message-search-form" role="search" onSubmit={(event) => void search(event)}>
          <label className="sr-only" htmlFor="message-search">Search accessible messages</label>
          <input id="message-search" type="search" value={query} onChange={(event) => queryChanged(event.target.value)} placeholder="Search messages" autoFocus data-initial-focus />
          <button className="button primary compact" type="submit" disabled={busy || !query.trim()}>{busy ? "Searching…" : "Search"}</button>
          <fieldset className="message-search-filters">
            <legend>Refine results</legend>
            <label>Conversation
              <select value={conversationId} onChange={(event) => { setConversationId(event.target.value); resetResults(); }}>
                <option value="all">All conversations</option>
                {conversations.map((conversation) => <option key={conversation.id} value={conversation.id}>{conversationTitle(conversation)}</option>)}
              </select>
            </label>
            <label>Sender
              <select value={senderId} onChange={(event) => { setSenderId(event.target.value); resetResults(); }}>
                <option value="all">Anyone</option>
                {users.map((user) => <option key={user.id} value={user.id}>{user.display_name}</option>)}
              </select>
            </label>
            <label>Date
              <select value={dateScope} onChange={(event) => { setDateScope(event.target.value as DateScope); resetResults(); }}>
                <option value="any">Any time</option>
                <option value="day">Past 24 hours</option>
                <option value="week">Past 7 days</option>
                <option value="month">Past 30 days</option>
              </select>
            </label>
          </fieldset>
          <p className="search-filter-note">Filters refine the authorized messages returned by this search.</p>
        </form>
        {error && <div className="form-error" role="alert">{error}</div>}
        {hasSearched && <p id="message-search-summary" className="search-result-summary" role="status" aria-live="polite" aria-atomic="true">{results.length} {results.length === 1 ? "result" : "results"} shown.</p>}
        {!busy && hasSearched && results.length === 0 && <p className="empty-copy">No accessible messages match this search.</p>}
        <ol className="search-results" aria-describedby={hasSearched ? "message-search-summary" : undefined}>
          {results.map((message, index) => {
            const conversation = conversationsById.get(message.conversation_id);
            return <li key={message.id}><button ref={(element) => { resultButtons.current[index] = element; }} type="button" onKeyDown={(event) => moveResultFocus(event, index)} onClick={() => onSelect(message)}><span><strong>{conversation ? conversationTitle(conversation) : "Conversation"}</strong><time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time></span><p>{message.body || "Message unavailable"}</p><small>{usersById.get(message.sender_user_id)?.display_name || "Unknown user"}</small></button></li>;
          })}
        </ol>
        {hasMore && <button className="button ghost full" type="button" disabled={busy || !cursor} onClick={() => void loadResults(cursor, true)}>{busy ? "Loading…" : "Load more results"}</button>}
      </aside>
    </div>
  );
}
