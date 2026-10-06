import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { useContextualNavigation } from "../../app/ContextualNavigation";
import { AppIcon } from "../../components/AppIcon";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { conversationTitle, errorText, formatDateTime } from "../../lib/format";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
import { callAvailabilityGuidance } from "./callAvailability";
import { CallReadinessLauncher } from "./CallReadinessLauncher";
import { CallLaunchButton, useCallSession } from "./CallSessionProvider";
import { CallTypeNavigation } from "./CallTypeNavigation";
import type {
  CallMediaKind,
  CallSummary,
  CallsScope,
  Conversation,
  DirectoryPerson,
  User
} from "../../types";
import { MeetingArtifactsPanel } from "../meeting-artifacts/MeetingArtifactsPanel";
import "./CallsPage.css";

const pageSize = 25;

type MediaFilter = "all" | CallMediaKind;

export function CallsPage() {
  const { api, session } = useSession();
  const { hasSidebarNavigation } = useContextualNavigation();
  const {
    conversations,
    users,
    capabilities,
    audioCallsAvailable,
    createConversation,
    startDirectConversation,
    loading: workspaceLoading,
    refreshCallAvailability,
    videoCallsAvailable
  } = useWorkspaceData();
  const { launchCall } = useCallSession();
  const [scope, setScope] = useState<CallsScope>("recent");
  const [historyConversation, setHistoryConversation] = useState("");
  const [historyStarter, setHistoryStarter] = useState("");
  const [fromDate, setFromDate] = useState("");
  const [toDate, setToDate] = useState("");
  const invalidDates = Boolean(fromDate && toDate && fromDate > toDate);
  const historyFiltered = Boolean(historyConversation || historyStarter || fromDate || toDate);
  const [people, setPeople] = useState<DirectoryPerson[]>([]);
  const [peopleLoading, setPeopleLoading] = useState(false);
  const [peopleError, setPeopleError] = useState<string | null>(null);
  const [callingPerson, setCallingPerson] = useState<string | null>(null);
  const peopleGeneration = useRef(0);
  const [mediaFilter, setMediaFilter] = useState<MediaFilter>("all");
  const [calls, setCalls] = useState<CallSummary[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [conversationQuery, setConversationQuery] = useState("");
  const [launcherPreference, setLauncherPreference] = useState<boolean | null>(null);
  const launcherSearchRef = useRef<HTMLInputElement>(null);
  const historyRef = useRef<HTMLElement>(null);
  const requestGeneration = useRef(0);

  useEffect(() => {
    if (launcherPreference === true) launcherSearchRef.current?.focus();
  }, [launcherPreference]);

  const loadCalls = useCallback(async (mode: "replace" | "append", cursor?: string | null) => {
    const generation = ++requestGeneration.current;
    if (invalidDates) { setLoading(false); setLoadingMore(false); return; }
    if (mode === "replace") setLoading(true);
    else setLoadingMore(true);
    setError(null);

    try {
      const page = await api.calls({
        scope,
        media_kind: mediaFilter === "all" ? undefined : mediaFilter,
        limit: pageSize,
        cursor,
        ...(historyConversation ? { conversation_id: historyConversation } : {}),
        ...(historyStarter ? { started_by_user_id: historyStarter } : {}),
        ...(fromDate ? { after: dateBoundary(fromDate) } : {}),
        ...(toDate ? { before: dateBoundary(toDate, true) } : {})
      });
      if (generation !== requestGeneration.current) return;
      setCalls((current) => mode === "append" ? mergeCalls(current, page.data) : page.data);
      setNextCursor(page.page.next_cursor);
      setHasMore(page.page.has_more);
    } catch (reason: unknown) {
      if (generation !== requestGeneration.current) return;
      setCalls([]); setNextCursor(null); setHasMore(false);
      setError(errorText(reason));
    } finally {
      if (generation === requestGeneration.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [api, mediaFilter, scope, historyConversation, historyStarter, fromDate, toDate, invalidDates]);

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
  useEffect(() => {
    const generation = ++peopleGeneration.current;
    const query = conversationQuery.trim();
    setPeople([]); setPeopleError(null); setCallingPerson(null);
    if (query.length < 2 || typeof api.directoryUsers !== "function") { setPeopleLoading(false); return; }
    setPeopleLoading(true);
    const timer = window.setTimeout(() => {
      void api.directoryUsers(query, 20).then(page => {
        if (generation === peopleGeneration.current) setPeople(page.data);
      }).catch(reason => {
        if (generation === peopleGeneration.current) setPeopleError(errorText(reason));
      }).finally(() => {
        if (generation === peopleGeneration.current) setPeopleLoading(false);
      });
    }, 200);
    return () => { window.clearTimeout(timer); peopleGeneration.current += 1; };
  }, [api, conversationQuery]);

  async function callPerson(person: DirectoryPerson, kind: CallMediaKind) {
    const generation = peopleGeneration.current;
    setCallingPerson(person.id); setPeopleError(null);
    try {
      const target = await startDirectConversation(person.id);
      if (generation === peopleGeneration.current) launchCall(target, kind);
    } catch (reason) {
      if (generation === peopleGeneration.current) setPeopleError(errorText(reason));
    } finally {
      if (generation === peopleGeneration.current) setCallingPerson(null);
    }
  }

  const callableConversations = useMemo(() => {
    const query = conversationQuery.trim().toLocaleLowerCase();
    return conversations
      .filter((conversation) => !conversation.archived_at)
      .filter((conversation) => !query || [conversationTitle(conversation), conversation.counterpart_display_name, conversation.counterpart_user_id ? userById.get(conversation.counterpart_user_id)?.email : null].some(value => value?.toLocaleLowerCase().includes(query)))
      .sort((left, right) => right.updated_at.localeCompare(left.updated_at))
      .slice(0, 8);
  }, [conversationQuery, conversations, userById]);
  const launcherExpanded = launcherPreference ?? false;

  if (!session) return null;

  const canUseAudio = !workspaceLoading
    && capabilities?.allow_audio_calls === true
    && audioCallsAvailable;
  const canUseVideo = !workspaceLoading
    && capabilities?.allow_video_calls === true
    && videoCallsAvailable;
  const callGuidance = !workspaceLoading && capabilities
    ? callAvailabilityGuidance({
        allowAudio: capabilities.allow_audio_calls === true,
        allowVideo: capabilities.allow_video_calls === true,
        audioAvailable: audioCallsAvailable,
        videoAvailable: videoCallsAvailable
      })
    : null;

  return (
    <main className="page-shell calls-page" id="main-content">
      <SurfaceHeader title="Calls" description="Internet audio and video calls with your workspace conversations." actions={<div className="calls-page-actions">
          <button className="button primary calls-start-action" type="button" onClick={() => {
            setLauncherPreference(true);
            launcherSearchRef.current?.focus();
          }}><AppIcon name="plus" />Start call</button>
          <button className="button ghost calls-join-action" type="button" onClick={() => {
            setScope("active");
            historyRef.current?.focus();
          }}><AppIcon name="users" />Join active call</button>
          <button
            className="button ghost calls-refresh-action"
            type="button"
            disabled={loading}
            aria-label={loading ? "Refreshing calls" : "Refresh calls"}
            onClick={() => {
              void Promise.allSettled([
                loadCalls("replace"),
                refreshCallAvailability()
              ]);
            }}
          >
            <AppIcon name="refresh" />
            <span>{loading ? "Refreshing…" : "Refresh"}</span>
          </button>
        </div>} />

      <div className="calls-navigation">
        <CallTypeNavigation active="internet" />
        {!hasSidebarNavigation && <nav className="calls-related-destinations" aria-label="Related calling destinations">
          <span>Related</span>
          <Link to="/app/meetings"><AppIcon name="clock" />Calendar</Link>
          <Link to="/app/artifacts"><AppIcon name="file" />Recordings</Link>
        </nav>}
      </div>

      <div className="calls-workspace">
        <button
          className="calls-new-call-toggle"
          type="button"
          aria-expanded={launcherExpanded}
          aria-controls="calls-launcher"
          onClick={() => setLauncherPreference(!launcherExpanded)}
        >
          {/* The glyph followed the control, not the action: a plus sat beside "Hide". */}
          <AppIcon name={launcherExpanded ? "chevronDown" : "plus"} />
          {launcherExpanded ? "Hide call launcher" : "Start call"}
        </button>

        <section
          className={`calls-launcher ${launcherExpanded ? "is-mobile-open" : ""}`}
          id="calls-launcher"
          aria-labelledby="new-call-heading"
        >
          <div className="calls-panel-heading">
            <div>
              <h2 id="new-call-heading">Start a call</h2>
              <p>Find a person or conversation. Preview your devices before connecting.</p>
            </div>
          </div>
          <label className="calls-search">
            <span className="sr-only">Find a conversation to call</span>
            <AppIcon name="search" />
            <input
              ref={launcherSearchRef}
              type="search"
              value={conversationQuery}
              placeholder="Find people or conversations"
              onChange={(event) => setConversationQuery(event.currentTarget.value)}
            />
          </label>
          {workspaceLoading ? (
            <p className="calls-availability-note call-availability-guidance" role="status">
              <span>Checking call availability…</span>
            </p>
          ) : callGuidance ? (
            <p className="calls-availability-note call-availability-guidance" role="status">
              <span>{callGuidance}</span>
            </p>
          ) : null}
          {!canUseAudio && !canUseVideo ? null : callableConversations.length === 0 ? (
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
                        <AppIcon name="message" />
                        Message
                      </Link>
                      {canUseAudio && (
                        <CallLaunchButton
                          conversation={conversation}
                          kind="audio"
                          ariaLabel={`Audio call ${title}`}
                        >
                          <AppIcon name="phone" />
                          Audio
                        </CallLaunchButton>
                      )}
                      {canUseVideo && (
                        <CallLaunchButton
                          conversation={conversation}
                          kind="video"
                          ariaLabel={`Video call ${title}`}
                        >
                          <AppIcon name="video" />
                          Video
                        </CallLaunchButton>
                      )}
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
          {peopleLoading && <p role="status">Finding people…</p>}
          {peopleError && <p className="inline-notice error" role="alert">{peopleError}</p>}
          {people.filter(person => person.id !== session.user.id && !callableConversations.some(conversation => conversation.counterpart_user_id === person.id)).length > 0 && <>
            <h3 className="calls-people-heading">People</h3>
            <ul className="calls-launch-list" aria-label="People matching your search">{people.filter(person => person.id !== session.user.id && !callableConversations.some(conversation => conversation.counterpart_user_id === person.id)).map(person => <li key={person.id}>
              <div className="calls-conversation-identity"><span aria-hidden="true"><AppIcon name="contact" /></span><div><strong>{participantIdentifier(person, duplicateParticipantNames(people))}</strong><small>Workspace member</small></div></div>
              <div className="calls-quick-actions">{canUseAudio && <button type="button" disabled={callingPerson !== null} aria-label={`Audio call ${participantIdentifier(person, duplicateParticipantNames(people))}`} onClick={() => void callPerson(person, "audio")}><AppIcon name="phone" />Audio</button>}{canUseVideo && <button type="button" disabled={callingPerson !== null} aria-label={`Video call ${participantIdentifier(person, duplicateParticipantNames(people))}`} onClick={() => void callPerson(person, "video")}><AppIcon name="video" />Video</button>}</div>
            </li>)}</ul>
            <p className="calls-people-note">Showing up to 20 matching people. Refine your search or open Directory for more.</p>
          </>}
          <Link className="calls-directory-link" to="/app/directory">
            <AppIcon name="contact" />
            Browse directory
            <AppIcon name="arrowUpRight" />
          </Link>
        </section>

        <section ref={historyRef} className="calls-history" aria-label="Call history" tabIndex={-1}>
          <div className="calls-section-heading">
            <div>
              <h2 id="call-sessions-heading">Call history</h2>
              <p>{scope === "active" ? "Conversations happening now." : "Your recent room sessions."}</p>
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
                <span className="sr-only">Media</span>
                <AppIcon name="filter" aria-hidden="true" />
                <select aria-label="Media" value={mediaFilter} onChange={(event) => setMediaFilter(event.currentTarget.value as MediaFilter)}>
                  <option value="all">All media</option>
                  <option value="audio">Audio</option>
                  <option value="video">Video</option>
                </select>
              </label>
            </div>
          </div>

          <details className="calls-history-filter-panel">
            <summary>Filter call history</summary>
          <fieldset className="calls-history-filters">
            <legend className="sr-only">Find call history</legend>
            <label>Conversation<select value={historyConversation} onChange={event => setHistoryConversation(event.target.value)}><option value="">All conversations</option>{conversations.map(conversation => <option key={conversation.id} value={conversation.id}>{conversationParticipantIdentifier(conversation, duplicateDirectNames)}</option>)}</select></label>
            <label>Started by<select value={historyStarter} onChange={event => setHistoryStarter(event.target.value)}><option value="">Anyone</option>{users.map(user => <option key={user.id} value={user.id}>{participantIdentifier(user, duplicateUserNames)}</option>)}</select></label>
            <label>From<input type="date" value={fromDate} max={toDate || undefined} onChange={event => setFromDate(event.target.value)} /></label>
            <label>Through<input type="date" value={toDate} min={fromDate || undefined} onChange={event => setToDate(event.target.value)} /></label>
            {historyFiltered && <button className="button ghost compact" type="button" onClick={() => { setHistoryConversation(""); setHistoryStarter(""); setFromDate(""); setToDate(""); }}>Clear history filters</button>}
            <p>Dates use your local time zone and match when the call started.</p>
          </fieldset>
          </details>
          {invalidDates && <p role="alert" className="inline-notice error">Choose an end date on or after the start date.</p>}
          {historyFiltered && !invalidDates && <p role="status" className="calls-filter-summary">Filtered history{historyConversation ? ` · ${conversationById.get(historyConversation) ? conversationTitle(conversationById.get(historyConversation)!) : "Selected conversation"}` : ""}{historyStarter ? ` · Started by ${userById.get(historyStarter)?.display_name || "selected person"}` : ""}{fromDate ? ` · From ${fromDate}` : ""}{toDate ? ` · Through ${toDate}` : ""}</p>}
          {error && (
            <div className="calls-state error" role="alert">
              <div>
                <strong>Call sessions could not be loaded.</strong>
                <span>{error}</span>
              </div>
              <button type="button" onClick={() => void loadCalls("replace")}>Try again</button>
            </div>
          )}

          {invalidDates ? null : loading && calls.length === 0 ? (
            <div className="calls-state" role="status" aria-live="polite">
              <span className="spinner" aria-hidden="true" />
              Loading call sessions…
            </div>
          ) : !error && calls.length === 0 ? (
            <div className="calls-state empty">
              <span className="calls-empty-illustration" aria-hidden="true">
                <AppIcon name={scope === "active" ? "phone" : "clock"} />
              </span>
              <strong>{historyFiltered ? "No calls match these filters" : scope === "active" ? "No active call rooms" : "No recent call rooms"}</strong>
              <span>{historyFiltered ? "Change or clear the filters to see more calls." : scope === "active" ? "Choose a conversation to start one." : "Completed room sessions will appear here."}</span>
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
                  audioEnabled={canUseAudio}
                  videoEnabled={canUseVideo}
                  availabilityChecking={workspaceLoading}
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


        <CallReadinessLauncher
          api={api}
          audioAvailable={canUseAudio}
          createConversation={createConversation}
        />
      </div>
    </main>
  );
}

function CallSessionRow({
  call,
  conversation,
  startedBy,
  duplicateDirectNames,
  duplicateUserNames,
  audioEnabled,
  videoEnabled,
  availabilityChecking
}: {
  call: CallSummary;
  conversation?: Conversation;
  startedBy?: User;
  duplicateDirectNames: ReadonlySet<string>;
  duplicateUserNames: ReadonlySet<string>;
  audioEnabled: boolean;
  videoEnabled: boolean;
  availabilityChecking: boolean;
}) {
  const { api } = useSession();
  const [artifactsOpen, setArtifactsOpen] = useState(false);
  const title = conversation
    ? conversationParticipantIdentifier(conversation, duplicateDirectNames)
    : "Conversation";
  const startedByIdentifier = startedBy
    ? participantIdentifier(startedBy, duplicateUserNames)
    : "a member";
  const active = call.status === "active";
  const ending = call.status === "ending";
  const mediaEnabled = call.media_kind === "audio" ? audioEnabled : videoEnabled;
  const time = active || ending ? call.started_at : call.ended_at || call.started_at;
  const action = active ? "Join" : "Start";
  const availabilitySuffix = availabilityChecking
    ? " (checking availability)"
    : mediaEnabled
      ? ""
      : " (unavailable)";
  return (
    <li className="call-session-row">
      <div className={`call-media-mark ${call.media_kind}`} aria-hidden="true">
        <AppIcon name={call.media_kind === "video" ? "video" : "phone"} />
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
          <span>Started by {startedByIdentifier}</span>
        </p>
        <p>
          <span>{active || ending ? "Started" : "Ended"} <time dateTime={time}>{formatDateTime(time)}</time></span>
          <span aria-hidden="true"> · </span>
          <span>{formatDuration(call.duration_seconds)} room duration</span>
        </p>
      </div>
      <div className="call-session-actions">
        {typeof api.meetingArtifacts === "function" && <button type="button" aria-expanded={artifactsOpen} aria-label={`View recordings and transcripts for ${title}`} onClick={() => setArtifactsOpen(value => !value)}><AppIcon name="file" />Recordings and transcripts</button>}
        <Link
          to={conversationPath(call.conversation_id)}
          aria-label={`Open chat for ${title}`}
        >
          <AppIcon name="message" />
          Open chat
        </Link>
        {ending ? (
          <span className="call-ending-note">Room closing</span>
        ) : conversation ? (
          <CallLaunchButton
            className="primary"
            conversation={conversation}
            kind={call.media_kind}
            disabled={availabilityChecking || !mediaEnabled}
            ariaLabel={`${action} ${call.media_kind} call for ${title}${availabilitySuffix}`}
          >
            <AppIcon name={call.media_kind === "video" ? "video" : "phone"} />
            {action} {call.media_kind}
          </CallLaunchButton>
        ) : (
          <span className="call-ending-note">Conversation unavailable</span>
        )}
      </div>
      {artifactsOpen && <div className="call-session-artifacts"><MeetingArtifactsPanel api={api} conversationId={call.conversation_id} callId={call.id} joined={false} /></div>}
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
      <span aria-hidden="true"><AppIcon name={conversation.kind === "direct" ? "atSign" : "hash"} /></span>
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
  return `/app/?${query.toString()}`;
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

function dateBoundary(value: string, followingDay = false): string {
  const [year, month, day] = value.split("-").map(Number);
  return new Date(year!, month! - 1, day! + (followingDay ? 1 : 0)).toISOString();
}
