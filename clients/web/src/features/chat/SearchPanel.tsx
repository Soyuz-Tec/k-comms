import { useEffect, useMemo, useRef, useState } from "react";
import type { FormEvent, KeyboardEvent as ReactKeyboardEvent } from "react";
import type { ApiClient } from "../../api";
import type { Conversation, Message, RetainedSenderLabel, User } from "../../types";
import { errorText, formatTime } from "../../lib/format";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  mergeRetainedSenderLabelMaps,
  participantIdentifier,
  retainedSenderLabelMap,
  resolveVisibleSenderIdentity,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";

type DateScope = "any" | "day" | "week" | "month";

const DATE_WINDOWS: Record<Exclude<DateScope, "any">, number> = {
  day: 24 * 60 * 60 * 1_000,
  week: 7 * 24 * 60 * 60 * 1_000,
  month: 30 * 24 * 60 * 60 * 1_000
};

const SENDER_LABEL_REFRESH_DELAYS_MS = [30_000, 60_000, 120_000, 300_000] as const;

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
  const [retainedSenderLabelsById, setRetainedSenderLabelsById] = useState(
    () => new Map<string, RetainedSenderLabel>()
  );
  const retainedSenderLabelsByIdRef = useRef(retainedSenderLabelsById);
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const duplicateDirectoryNames = useMemo(
    () => duplicateParticipantNames(users),
    [users]
  );
  const visibleSenderIdentities = useMemo(() => {
    const identitiesById = new Map<string, ParticipantIdentity>();
    for (const message of results) {
      const identity = resolveVisibleSenderIdentity(
        message.sender_user_id,
        new Map(),
        retainedSenderLabelsById,
        [usersById]
      );
      if (identity) identitiesById.set(identity.id, identity);
    }
    return identitiesById;
  }, [results, retainedSenderLabelsById, usersById]);
  const duplicateVisibleSenderNames = useMemo(
    () => duplicateParticipantNames(visibleSenderIdentities.values()),
    [visibleSenderIdentities]
  );
  const conversationsById = useMemo(
    () => new Map(conversations.map((conversation) => [conversation.id, conversation])),
    [conversations]
  );
  const duplicateDirectNames = useMemo(
    () => duplicateDirectConversationNames(conversations),
    [conversations]
  );
  const resultButtons = useRef<Array<HTMLButtonElement | null>>([]);
  const requestId = useRef(0);
  const submittedAfter = useRef<string | undefined>(undefined);
  const senderLabelRefreshInFlightRef = useRef(false);
  const dialogRef = useModalDialog(onClose);

  useEffect(() => {
    retainedSenderLabelsByIdRef.current = retainedSenderLabelsById;
  }, [retainedSenderLabelsById]);

  useEffect(() => {
    const messageIdsByConversation =
      senderLabelMessageIdsByConversation(results);
    if (messageIdsByConversation.size === 0) return;
    let current = true;
    let timeout: number | undefined;
    let backoffIndex = 0;

    const scheduleRefresh = () => {
      if (!current || document.hidden) return;
      if (timeout !== undefined) window.clearTimeout(timeout);
      timeout = window.setTimeout(() => {
        timeout = undefined;
        void refreshSenderLabels();
      }, SENDER_LABEL_REFRESH_DELAYS_MS[backoffIndex]);
    };

    const refreshSenderLabels = async () => {
      if (document.hidden) return;
      if (senderLabelRefreshInFlightRef.current) {
        scheduleRefresh();
        return;
      }
      senderLabelRefreshInFlightRef.current = true;
      let labelsChanged = false;
      try {
        const settled = await Promise.allSettled(
          [...messageIdsByConversation].map(
            ([resultConversationId, messageIds]) =>
              api.messageSenderLabels(
                resultConversationId,
                messageIds
              )
          )
        );
        if (!current) return;
        const labels = settled.flatMap((result) =>
          result.status === "fulfilled"
            ? result.value
            : []
        );
        if (labels.length > 0) {
          const existing = retainedSenderLabelsByIdRef.current;
          const merged = mergeRetainedSenderLabels(existing, labels);
          labelsChanged = !retainedSenderLabelMapsEqual(existing, merged);
          if (labelsChanged) {
            retainedSenderLabelsByIdRef.current = merged;
            setRetainedSenderLabelsById(merged);
          }
        }
      } catch {
        // This reconciliation is best effort and retries with bounded backoff.
      } finally {
        senderLabelRefreshInFlightRef.current = false;
        if (current) {
          backoffIndex = labelsChanged
            ? 0
            : Math.min(
                backoffIndex + 1,
                SENDER_LABEL_REFRESH_DELAYS_MS.length - 1
              );
          scheduleRefresh();
        }
      }
    };

    const visibilityChanged = () => {
      if (!current) return;
      if (document.hidden) {
        if (timeout !== undefined) window.clearTimeout(timeout);
        timeout = undefined;
        return;
      }
      backoffIndex = 0;
      scheduleRefresh();
    };

    document.addEventListener("visibilitychange", visibilityChanged);
    scheduleRefresh();
    return () => {
      current = false;
      if (timeout !== undefined) window.clearTimeout(timeout);
      document.removeEventListener("visibilitychange", visibilityChanged);
    };
  }, [api, results]);

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
      setRetainedSenderLabelsById((current) =>
        append
          ? mergeRetainedSenderLabels(current, response.included?.sender_labels)
          : retainedSenderLabelMap(response.included?.sender_labels)
      );
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
        setRetainedSenderLabelsById(new Map());
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
    setRetainedSenderLabelsById(new Map());
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

  function resultSenderIdentifier(userId: string): string {
    const identity = visibleSenderIdentities.get(userId);
    return identity
      ? participantIdentifier(identity, duplicateVisibleSenderNames)
      : "Unknown user";
  }

  return (
    <div className="drawer-backdrop">
      <aside ref={dialogRef} className="search-panel" role="dialog" aria-modal="true" aria-labelledby="message-search-title">
        <header>
          <div><span className="eyebrow">Authorized results</span><h2 id="message-search-title">Search messages</h2></div>
          <AppSurfaceControlButton
            accessibleLabel="Close search"
            kind="close"
            onClick={onClose}
          />
        </header>
        <form className="search-form message-search-form" role="search" onSubmit={(event) => void search(event)}>
          <label className="sr-only" htmlFor="message-search">Search accessible messages</label>
          <input id="message-search" type="search" value={query} onChange={(event) => queryChanged(event.target.value)} placeholder="Search messages" autoFocus data-initial-focus />
          <button className="button primary compact" type="submit" disabled={busy || !query.trim()}>{busy ? "Searching…" : "Search"}</button>
          <fieldset className="message-search-filters">
            <legend>Refine results</legend>
            <label>Conversation
              <select value={conversationId} onChange={(event) => { setConversationId(event.target.value); resetResults(); }}>
                <option value="all">All conversations</option>
                {conversations.map((conversation) => <option key={conversation.id} value={conversation.id}>{conversationParticipantIdentifier(conversation, duplicateDirectNames)}</option>)}
              </select>
            </label>
            <label>Sender
              <select value={senderId} onChange={(event) => { setSenderId(event.target.value); resetResults(); }}>
                <option value="all">Anyone</option>
                {users.map((user) => <option key={user.id} value={user.id}>{participantIdentifier(user, duplicateDirectoryNames)}</option>)}
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
            return <li key={message.id}><button ref={(element) => { resultButtons.current[index] = element; }} type="button" onKeyDown={(event) => moveResultFocus(event, index)} onClick={() => onSelect(message)}><span><strong>{conversation ? conversationParticipantIdentifier(conversation, duplicateDirectNames) : "Conversation"}</strong><time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time></span><p>{message.body || "Message unavailable"}</p><small>{resultSenderIdentifier(message.sender_user_id)}</small></button></li>;
          })}
        </ol>
        {hasMore && <button className="button ghost full" type="button" disabled={busy || !cursor} onClick={() => void loadResults(cursor, true)}>{busy ? "Loading…" : "Load more results"}</button>}
      </aside>
    </div>
  );
}

function mergeRetainedSenderLabels(
  current: Map<string, RetainedSenderLabel>,
  incoming: RetainedSenderLabel[] | undefined
): Map<string, RetainedSenderLabel> {
  return mergeRetainedSenderLabelMaps(current, incoming);
}

function retainedSenderLabelMapsEqual(
  left: ReadonlyMap<string, RetainedSenderLabel>,
  right: ReadonlyMap<string, RetainedSenderLabel>
): boolean {
  if (left.size !== right.size) return false;
  for (const [id, label] of left) {
    const candidate = right.get(id);
    if (
      !candidate ||
      candidate.display_name !== label.display_name ||
      candidate.redacted !== label.redacted
    ) {
      return false;
    }
  }
  return true;
}

function senderLabelMessageIdsByConversation(
  messages: Message[]
): Map<string, string[]> {
  const messageIdsByConversationAndSender = new Map<
    string,
    Map<string, string>
  >();
  for (const message of messages) {
    const messageIdsBySender =
      messageIdsByConversationAndSender.get(message.conversation_id) ||
      new Map<string, string>();
    if (!messageIdsBySender.has(message.sender_user_id)) {
      messageIdsBySender.set(message.sender_user_id, message.id);
    }
    messageIdsByConversationAndSender.set(
      message.conversation_id,
      messageIdsBySender
    );
  }
  return new Map(
    [...messageIdsByConversationAndSender].map(
      ([resultConversationId, messageIdsBySender]) => [
        resultConversationId,
        [...messageIdsBySender.values()]
      ]
    )
  );
}
