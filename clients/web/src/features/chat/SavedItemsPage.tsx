import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router";
import { useSession } from "../../app/session";
import { useOptionalWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { AvatarBadge } from "../../components/AvatarBadge";
import { errorText, formatDateTime } from "../../lib/format";
import { conversationParticipantIdentifier, duplicateDirectConversationNames, duplicateParticipantNames, participantIdentifier } from "../../lib/participantIdentity";
import type { Message } from "../../types";
import "./SavedItemsPage.css";

export function SavedItemsPage() {
  const { api, session } = useSession();
  const generation = useMemo(() => crypto.randomUUID(), [api,
    session?.access_token, session?.refresh_token, session?.tenant.id, session?.tenant.status,
    session?.user.id, session?.user.tenant_id, session?.user.role, session?.user.status,
    session?.user.version, session?.user.account_type, session?.user.access_scope,
    session?.device.id, session?.device.user_id, session?.device.revoked_at
  ]);
  return <SavedItemsForIdentity key={generation} />;
}

function SavedItemsForIdentity() {
  const { api } = useSession();
  const workspace = useOptionalWorkspaceData();
  const users = workspace?.users;
  const conversations = workspace?.conversations;
  const userById = useMemo(() => new Map(users?.map(user => [user.id, user])), [users]);
  const conversationById = useMemo(() => new Map(conversations?.map(conversation => [conversation.id, conversation])), [conversations]);
  const duplicateUsers = useMemo(() => duplicateParticipantNames(users || []), [users]);
  const duplicateConversations = useMemo(() => duplicateDirectConversationNames(conversations || []), [conversations]);
  const [items, setItems] = useState<Message[]>([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(true);
  const [cursor, setCursor] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [removingId, setRemovingId] = useState<string | null>(null);
  const [removed, setRemoved] = useState<Message | null>(null);
  const scope = useRef(0);
  function accessDenied(reason: unknown) {
    return Boolean(reason && typeof reason === "object" && "status" in reason && [401, 403, 404].includes(Number(reason.status)));
  }
  function fail(reason: unknown) {
    if (accessDenied(reason)) { setItems([]); setCursor(null); setRemoved(null); }
    setError(errorText(reason));
  }
  useEffect(() => {
    const generation = ++scope.current;
    setItems([]); setCursor(null); setRemoved(null); setRemovingId(null); setBusy(true); setError("");
    void api.savedItems().then(page => { if (scope.current === generation) { setItems(page.data); setCursor(page.page.next_cursor || null); } })
      .catch(e => { if (scope.current === generation) fail(e); }).finally(() => { if (scope.current === generation) setBusy(false); });
    return () => { scope.current++; };
  }, [api, attempt]);
  async function more() {
    if (!cursor || busy) return;
    const generation = scope.current;
    setBusy(true); setError("");
    try {
      const page = await api.savedItems(cursor);
      if (scope.current !== generation) return;
      setItems(current => [...current, ...page.data].filter((item, index, all) => all.findIndex(other => other.id === item.id) === index)); setCursor(page.page.next_cursor || null);
    } catch (e) { if (scope.current === generation) fail(e); }
    finally { if (scope.current === generation) setBusy(false); }
  }
  async function remove(item: Message) {
    if (removingId || busy) return;
    const generation = scope.current;
    setError(""); setRemovingId(item.id);
    try {
      await api.unsaveMessage(item.id);
      if (scope.current !== generation) return;
      setItems(current => current.filter(value => value.id !== item.id)); setRemoved(item);
    } catch (e) { if (scope.current === generation) fail(e); }
    finally { if (scope.current === generation) setRemovingId(null); }
  }
  async function undo() {
    if (!removed || busy || removingId) return;
    const item = removed, generation = scope.current;
    setBusy(true); setError("");
    try {
      await api.saveMessage(item.id);
      if (scope.current !== generation) return;
      setItems(current => current.some(value => value.id === item.id) ? current : [item, ...current]); setRemoved(null);
    } catch (e) { if (scope.current === generation) fail(e); }
    finally { if (scope.current === generation) setBusy(false); }
  }
  return <main id="main-content" className="page-shell saved-items-page" aria-busy={busy}>
    <SurfaceHeader title="Saved items" back={{ to: "/app/content", label: "Content" }} description="Your private collection of messages to revisit." />
    <p className="saved-items-access">Saved messages remain available while you have access to their conversations.</p>
    {error && <p className="form-error" role="alert">{error} <button className="button ghost" type="button" onClick={() => setAttempt(v => v + 1)}>Retry saved items</button></p>}
    {removed && <div className="saved-items-feedback" role="status"><span>Removed from saved items.</span><button className="button ghost compact" type="button" disabled={busy || Boolean(removingId)} onClick={() => void undo()}>Undo</button></div>}
    {busy && items.length === 0 && !removed && <p role="status">Loading saved messages…</p>}
    {!busy && !error && items.length === 0 && !cursor && <section className="empty-state"><AppIcon name="bookmark" /><h2>No saved messages yet</h2><p>Use Save on a message to keep it here.</p><Link className="button ghost" to="/app/">Open Inbox</Link></section>}
    <ul className="saved-items-list" aria-label="Saved messages">{items.map(item => {
      const sender = userById.get(item.sender_user_id);
      const senderName = sender ? participantIdentifier(sender, duplicateUsers) : "Sender unavailable";
      const conversation = conversationById.get(item.conversation_id);
      const context = conversation ? conversationParticipantIdentifier(conversation, duplicateConversations) : "Conversation";
      return <li className="saved-message-card" key={item.id}>
        <AvatarBadge name={senderName} avatarUrl={sender?.avatar_url} size="small" />
        <article className="saved-message-copy">
          <div className="saved-message-context"><strong>{senderName}</strong><span>in {context}</span></div>
          <time dateTime={item.inserted_at}>Message sent {formatDateTime(item.inserted_at)}</time>
          <Link className="saved-message-source" to={`/app/?conversation=${encodeURIComponent(item.conversation_id)}&message=${encodeURIComponent(item.id)}`}><span>{item.body || "Attachment message"}</span><small>Open source message <AppIcon name="arrowUpRight" /></small></Link>
          {item.attachments.length > 0 && <p className="saved-message-attachments"><AppIcon name="paperclip" />{item.attachments.map(attachment => attachment.file_name).join(" · ")}</p>}
        </article>
        <button className="button ghost saved-message-remove" type="button" disabled={busy || Boolean(removingId)} onClick={() => void remove(item)} aria-label={`Remove saved message ${item.conversation_sequence}`} title="Remove from saved items"><AppIcon name="bookmark" /><span className="visually-hidden">{removingId === item.id ? "Removing…" : "Remove"}</span></button>
      </li>;
    })}</ul>{cursor && <button className="button ghost" type="button" disabled={busy} onClick={() => void more()}>More saved messages</button>}
  </main>;
}
