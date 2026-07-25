import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { conversationTitle, errorText, formatDateTime } from "../../lib/format";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
import { CallLaunchButton } from "./CallSessionProvider";
import type {
  CallMediaKind,
  CallSummary,
  CallsScope,
  Conversation,
  User
} from "../../types";
import "./CallsPage.css";

const pageSize = 25;

type MediaFilter = "all" | CallMediaKind;

export function CallsPage() {
  const { api, session } = useSession();
  const {
    conversations,
    users,
    capabilities,
    audioCallsAvailable,
    videoCallsAvailable
  } = useWorkspaceData();
  const [scope, setScope] = useState<CallsScope>("active");
  const [mediaFilter, setMediaFilter] = useState<MediaFilter>("all");
  const [calls, setCalls] = useState<CallSummary[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [conversationQuery, setConversationQuery] = useState("");
  const requestGeneration = useRef(0);

  const loadCalls = useCallback(async (mode: "replace" | "append", cursor?: string | null) => {
    const generation = ++requestGeneration.current;
    if (mode === "replace") setLoading(true);
    else setLoadingMore(true);
    setError(null);

    try {
      const page = await api.calls({
        scope,
        media_kind: mediaFilter === "all" ? undefined : mediaFilter,
        limit: pageSize,
        cursor
      });
      if (generation !== requestGeneration.current) return;
      setCalls((current) => mode === "append" ? mergeCalls(current, page.data) : page.data);
      setNextCursor(page.page.next_cursor);
      setHasMore(page.page.has_more);
    } catch (reason: unknown) {
      if (generation !== requestGeneration.current) return;
      setError(errorText(reason));
    } finally {
      if (generation === requestGeneration.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [api, mediaFilter, scope]);

  useEffect(() => {
    setCalls([]);
    setNextCursor(null);
    setHasMore(false);
    void loadCalls("replace");
    return () => {
      requestGeneration.current += 1;
    };
  }, [loadCalls]);

  useEffect(() => {
    if (scope !== "active") return;
    const refresh = () => void loadCalls("replace");
    const timer = window.setInterval(refresh, 15_000);
    window.addEventListener("focus", refresh);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
    };
  }, [loadCalls, scope]);

  const conversationById = useMemo(
    () => new Map(conversations.map((conversation) => [conversation.id, conversation])),
    [conversations]
  );
  const userById = useMemo(
    () => new Map(users.map((user) => [user.id, user])),
    [users]
  );
  const duplicateDirectNames = useMemo(
    () => duplicateDirectConversationNames(conversations),
    [conversations]
  );
  const duplicateUserNames = useMemo(
    () => duplicateParticipantNames(users),
    [users]
  );
  const callableConversations = useMemo(() => {
    const query = conversationQuery.trim().toLocaleLowerCase();
    return conversations
      .filter((conversation) => !conversation.archived_at)
      .filter((conversation) => !query || conversationTitle(conversation).toLocaleLowerCase().includes(query))
      .sort((left, right) => right.updated_at.localeCompare(left.updated_at))
      .slice(0, 8);
  }, [conversationQuery, conversations]);

  if (!session) return null;

  const canUseAudio = capabilities?.allow_audio_calls === true && audioCallsAvailable;
  const canUseVideo = capabilities?.allow_video_calls === true && videoCallsAvailable;

  return (
    <main className="page-shell calls-page" id="main-content">
      <header className="page-heading calls-page-heading">
        <div>
          <span className="eyebrow">Workspace communication</span>
          <h1>Calls</h1>
          <p>Join an active room, review recent room sessions, or start a call from an existing conversation.</p>
        </div>
        <button
          className="button ghost"
          type="button"
          disabled={loading}
          onClick={() => void loadCalls("replace")}
        >
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      <section className="calls-launcher" aria-labelledby="new-call-heading">
        <div className="calls-section-heading">
          <div>
            <span className="eyebrow">One-step launch</span>
            <h2 id="new-call-heading">Start from a conversation</h2>
          </div>
          <label className="calls-search">
            <span className="sr-only">Find a conversation to call</span>
            <input
              type="search"
              value={conversationQuery}
              placeholder="Find a conversation"
              onChange={(event) => setConversationQuery(event.currentTarget.value)}
            />
          </label>
        </div>
        {!canUseAudio && !canUseVideo ? (
          <p className="calls-availability-note">Calling is unavailable for this workspace or environment.</p>
        ) : callableConversations.length === 0 ? (
          <p className="empty-copy">No matching conversations.</p>
        ) : (
          <ul className="calls-launch-list">
            {callableConversations.map((conversation) => {
              const title = conversationParticipantIdentifier(
                conversation,
                duplicateDirectNames
              );
              return (
                <li key={conversation.id}>
                  <ConversationIdentity conversation={conversation} title={title} />
                  <div className="calls-quick-actions">
                    <Link
                      to={conversationPath(conversation.id)}
                      aria-label={`Message ${title}`}
                    >
                      Message
                    </Link>
                    {canUseAudio && (
                      <CallLaunchButton
                        conversation={conversation}
                        kind="audio"
                        ariaLabel={`Audio call ${title}`}
                      >
                        Audio
                      </CallLaunchButton>
                    )}
                    {canUseVideo && (
                      <CallLaunchButton
                        conversation={conversation}
                        kind="video"
                        ariaLabel={`Video call ${title}`}
                      >
                        Video
                      </CallLaunchButton>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      <section className="calls-history" aria-labelledby="call-sessions-heading">
        <div className="calls-section-heading">
          <div>
            <span className="eyebrow">Room lifecycle</span>
            <h2 id="call-sessions-heading">Call sessions</h2>
          </div>
          <div className="calls-filter-stack">
            <fieldset className="calls-segments">
              <legend className="sr-only">Call session state</legend>
              <button type="button" aria-pressed={scope === "active"} onClick={() => setScope("active")}>
                Active
              </button>
              <button type="button" aria-pressed={scope === "recent"} onClick={() => setScope("recent")}>
                Recent
              </button>
            </fieldset>
            <label className="calls-media-filter">
              <span>Media</span>
              <select value={mediaFilter} onChange={(event) => setMediaFilter(event.currentTarget.value as MediaFilter)}>
                <option value="all">All</option>
                <option value="audio">Audio</option>
                <option value="video">Video</option>
              </select>
            </label>
          </div>
        </div>

        {error && (
          <div className="calls-state error" role="alert">
            <div>
              <strong>Call sessions could not be loaded.</strong>
              <span>{error}</span>
            </div>
            <button type="button" onClick={() => void loadCalls("replace")}>Try again</button>
          </div>
        )}

        {loading && calls.length === 0 ? (
          <div className="calls-state" role="status" aria-live="polite">
            <span className="spinner" aria-hidden="true" />
            Loading call sessions…
          </div>
        ) : !error && calls.length === 0 ? (
          <div className="calls-state empty">
            <strong>{scope === "active" ? "No active call rooms" : "No recent call rooms"}</strong>
            <span>{scope === "active" ? "Start one from a conversation above." : "Completed room sessions will appear here."}</span>
          </div>
        ) : (
          <ol className="call-session-list" aria-busy={loadingMore}>
            {calls.map((call) => (
              <CallSessionRow
                key={call.id}
                call={call}
                conversation={conversationById.get(call.conversation_id)}
                startedBy={userById.get(call.started_by_user_id)}
                duplicateDirectNames={duplicateDirectNames}
                duplicateUserNames={duplicateUserNames}
              />
            ))}
          </ol>
        )}

        {hasMore && !error && (
          <button
            className="calls-load-more"
            type="button"
            disabled={loadingMore || !nextCursor}
            onClick={() => void loadCalls("append", nextCursor)}
          >
            {loadingMore ? "Loading…" : "Load more sessions"}
          </button>
        )}
      </section>
    </main>
  );
}

function CallSessionRow({
  call,
  conversation,
  startedBy,
  duplicateDirectNames,
  duplicateUserNames
}: {
  call: CallSummary;
  conversation?: Conversation;
  startedBy?: User;
  duplicateDirectNames: ReadonlySet<string>;
  duplicateUserNames: ReadonlySet<string>;
}) {
  const title = conversation
    ? conversationParticipantIdentifier(conversation, duplicateDirectNames)
    : "Conversation";
  const startedByIdentifier = startedBy
    ? participantIdentifier(startedBy, duplicateUserNames)
    : "a member";
  const active = call.status === "active";
  const ending = call.status === "ending";
  const time = active || ending ? call.started_at : call.ended_at || call.started_at;
  return (
    <li className="call-session-row">
      <div className={`call-media-mark ${call.media_kind}`} aria-hidden="true">
        {call.media_kind === "video" ? "▣" : "◖"}
      </div>
      <div className="call-session-copy">
        <div className="call-session-title">
          <strong>{title}</strong>
          <span className={`calls-status ${active ? "active" : ending ? "ending" : "ended"}`}>
            {active ? "Active room" : ending ? "Ending room" : "Ended room"}
          </span>
        </div>
        <p>
          <span>{call.media_kind === "video" ? "Video" : "Audio"}</span>
          <span aria-hidden="true"> · </span>
          <span>{active || ending ? "Started" : "Ended"} by {startedByIdentifier}</span>
        </p>
        <p>
          <time dateTime={time}>{formatDateTime(time)}</time>
          <span aria-hidden="true"> · </span>
          <span>{formatDuration(call.duration_seconds)} room duration</span>
        </p>
      </div>
      <div className="call-session-actions">
        <Link
          to={conversationPath(call.conversation_id)}
          aria-label={`Open chat for ${title}`}
        >
          Open chat
        </Link>
        {ending ? (
          <span className="call-ending-note">Room closing</span>
        ) : conversation ? (
          <CallLaunchButton
            className="primary"
            conversation={conversation}
            kind={call.media_kind}
            ariaLabel={`${active ? "Join" : "Open"} ${call.media_kind} call for ${title}`}
          >
            {active ? `Join ${call.media_kind}` : `Start ${call.media_kind}`}
          </CallLaunchButton>
        ) : (
          <span className="call-ending-note">Conversation unavailable</span>
        )}
      </div>
    </li>
  );
}

function ConversationIdentity({
  conversation,
  title
}: {
  conversation: Conversation;
  title: string;
}) {
  return (
    <div className="calls-conversation-identity">
      <span aria-hidden="true">{conversation.kind === "direct" ? "@" : "#"}</span>
      <div>
        <strong>{title}</strong>
        <small>{conversation.kind === "direct" ? "Direct conversation" : `${conversation.kind} conversation`}</small>
      </div>
    </div>
  );
}

function mergeCalls(current: CallSummary[], incoming: CallSummary[]): CallSummary[] {
  const byId = new Map(current.map((call) => [call.id, call]));
  incoming.forEach((call) => byId.set(call.id, call));
  return [...byId.values()];
}

function conversationPath(conversationId: string): string {
  const query = new URLSearchParams({ conversation: conversationId });
  return `/app?${query.toString()}`;
}

function formatDuration(seconds: number): string {
  const safeSeconds = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  const hours = Math.floor(safeSeconds / 3_600);
  const minutes = Math.floor((safeSeconds % 3_600) / 60);
  const remainder = safeSeconds % 60;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${remainder}s`;
  return `${remainder}s`;
}
