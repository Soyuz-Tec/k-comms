import { useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient, SendMessageInput } from "../../api";
import { useModalDialog } from "../../components/useModalDialog";
import { clientMessageId, errorText, formatTime } from "../../lib/format";
import type { ConversationMembership, Message, User } from "../../types";
import { MentionPicker } from "./MentionPicker";

export function ThreadDrawer({
  api,
  conversationId,
  targetMessageId,
  currentUserId,
  members,
  users,
  liveMessages,
  onClose,
  onSend
}: {
  api: ApiClient;
  conversationId: string;
  targetMessageId: string;
  currentUserId: string;
  members: ConversationMembership[];
  users: User[];
  liveMessages: Message[];
  onClose: () => void;
  onSend: (input: SendMessageInput) => Promise<Message>;
}) {
  const [root, setRoot] = useState<Message | null>(null);
  const [replies, setReplies] = useState<Message[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [beforeSequence, setBeforeSequence] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const [sending, setSending] = useState(false);
  const [composer, setComposer] = useState("");
  const [mentionedUserIds, setMentionedUserIds] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const dialogRef = useModalDialog(onClose);

  useEffect(() => {
    let current = true;
    setLoading(true);
    setError(null);
    void api
      .messageThread(conversationId, targetMessageId)
      .then((thread) => {
        if (!current) return;
        setRoot(thread.data.root);
        setReplies(thread.data.replies);
        setHasMore(thread.page.has_more);
        setBeforeSequence(thread.page.next_before_sequence);
      })
      .catch((reason: unknown) => current && setError(errorText(reason)))
      .finally(() => current && setLoading(false));
    return () => { current = false; };
  }, [api, conversationId, targetMessageId]);

  useEffect(() => {
    if (!root) return;
    const relevant = liveMessages.filter(
      (message) => message.id === root.id || message.thread_root_message_id === root.id
    );
    const rootUpdate = relevant.find((message) => message.id === root.id);
    if (rootUpdate) setRoot(rootUpdate);
    const incomingReplies = relevant.filter((message) => message.id !== root.id);
    if (incomingReplies.length > 0) {
      setReplies((current) => mergeMessages(current, incomingReplies));
    }
  }, [liveMessages, root?.id]);

  async function loadOlder() {
    if (!root || !hasMore || beforeSequence === null || loadingOlder) return;
    setLoadingOlder(true);
    setError(null);
    try {
      const thread = await api.messageThread(conversationId, root.id, beforeSequence);
      setReplies((current) => mergeMessages(thread.data.replies, current));
      setHasMore(thread.page.has_more);
      setBeforeSequence(thread.page.next_before_sequence);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setLoadingOlder(false);
    }
  }

  async function send(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = composer.trim();
    if (!root || !body || sending) return;
    setSending(true);
    setError(null);
    try {
      const reply = await onSend({
        client_message_id: clientMessageId(),
        body,
        attachment_ids: [],
        mentioned_user_ids: mentionedUserIds,
        reply_to_message_id: root.id
      });
      setReplies((current) => mergeMessages(current, [reply]));
      setComposer("");
      setMentionedUserIds([]);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setSending(false);
    }
  }

  return (
    <div className="drawer-backdrop thread-backdrop">
      <aside ref={dialogRef} className="thread-drawer" role="dialog" aria-modal="true" aria-labelledby="thread-title">
        <header>
          <div><span className="eyebrow">Conversation thread</span><h2 id="thread-title">Thread</h2></div>
          <button className="icon-button" type="button" aria-label="Close thread" onClick={onClose}>×</button>
        </header>
        {error && <div className="form-error" role="alert">{error}</div>}
        {loading ? <div className="inline-loading" aria-busy="true"><span className="spinner" aria-hidden="true" />Loading thread…</div> : root && (
          <>
            <ThreadMessage message={root} user={usersById.get(root.sender_user_id)} currentUserId={currentUserId} root />
            <div className="thread-divider"><span>{Math.max(root.thread_reply_count || 0, replies.length)} replies</span></div>
            {hasMore && <button className="button ghost compact thread-load" type="button" disabled={loadingOlder} onClick={() => void loadOlder()}>{loadingOlder ? "Loading…" : "Load older replies"}</button>}
            <ol className="thread-replies" aria-live="polite">
              {replies.map((message) => <ThreadMessage key={message.id} message={message} user={usersById.get(message.sender_user_id)} currentUserId={currentUserId} />)}
            </ol>
            <form className="thread-composer" onSubmit={(event) => void send(event)}>
              <MentionPicker members={members} currentUserId={currentUserId} selectedUserIds={mentionedUserIds} disabled={sending} onChange={setMentionedUserIds} />
              <label htmlFor="thread-composer">Reply in thread</label>
              <textarea id="thread-composer" rows={3} value={composer} onChange={(event) => setComposer(event.target.value)} maxLength={65_535} disabled={sending} data-initial-focus />
              <button className="button primary compact" type="submit" disabled={sending || !composer.trim()}>{sending ? "Sending…" : "Reply"}</button>
            </form>
          </>
        )}
      </aside>
    </div>
  );
}

function ThreadMessage({ message, user, currentUserId, root = false }: { message: Message; user?: User; currentUserId: string; root?: boolean }) {
  return (
    <article className={`thread-message ${root ? "thread-root" : ""}`}>
      <header><strong>{message.sender_user_id === currentUserId ? "You" : user?.display_name || "Unknown user"}</strong><time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time></header>
      <p className={message.status === "active" ? "" : "removed"}>{message.status === "active" ? message.body : "Message removed"}</p>
    </article>
  );
}

function mergeMessages(current: Message[], incoming: Message[]): Message[] {
  const byId = new Map(current.map((message) => [message.id, message]));
  incoming.forEach((message) => byId.set(message.id, message));
  return [...byId.values()].sort(
    (left, right) => left.conversation_sequence - right.conversation_sequence
  );
}
