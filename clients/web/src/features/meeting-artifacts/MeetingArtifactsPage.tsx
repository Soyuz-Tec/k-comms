import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { conversationTitle, errorText, formatDateTime } from "../../lib/format";
import { duplicateParticipantNames, participantIdentifier } from "../../lib/participantIdentity";
import type { CallSummary } from "../../types";
import { MeetingArtifactsPanel } from "./MeetingArtifactsPanel";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function MeetingArtifactsPage() {
  const { api, session } = useSession();
  const identityGeneration = useMemo(() => crypto.randomUUID(), [api,
    session?.access_token, session?.refresh_token, session?.tenant.id, session?.tenant.status,
    session?.user.id, session?.user.tenant_id, session?.user.role, session?.user.status,
    session?.user.version, session?.user.account_type, session?.user.access_scope,
    session?.device.id, session?.device.user_id, session?.device.revoked_at
  ]);
  const { conversations } = useWorkspaceData();
  const [params] = useSearchParams();
  const conversationId = params.get("conversation") || "";
  const callId = params.get("call") || "";
  const artifactId = params.get("artifact") || undefined;
  const referenced = params.has("conversation") || params.has("call") || params.has("artifact");
  const valid = uuid.test(conversationId) && uuid.test(callId) && (!artifactId || uuid.test(artifactId));
  const conversation = conversations.find(item => item.id === conversationId);
  return <main id="main-content" className="member-page artifacts-page">
    <SurfaceHeader title="Meeting recordings and transcripts" description="Find saved meeting content by conversation and call date." back={referenced ? { to: "/app/artifacts", label: "All recent calls" } : undefined} actions={<Link className="button ghost" to="/app/calls">Calls</Link>} />
    {valid ? <>
      <section className="artifacts-context surface-card" aria-label="Selected call">
        <div><span className="artifacts-eyebrow">Conversation</span><h2>{conversation ? conversationTitle(conversation) : "Selected conversation"}</h2><p>Saved content from this call follows your current membership and workspace retention policy.</p></div>
        <Link className="button ghost" to={`/app/?conversation=${encodeURIComponent(conversationId)}`}>Open conversation</Link>
      </section>
      <MeetingArtifactsPanel key={identityGeneration} api={api} conversationId={conversationId} callId={callId} artifactId={artifactId} />
    </> : referenced ? <div className="surface-empty" role="alert"><strong>This recording link is incomplete.</strong><p>Open a recording from call history or workspace search.</p><Link className="button ghost" to="/app/artifacts">Browse recent calls</Link></div> : <RecentArtifactCalls key={identityGeneration} />}
  </main>;
}

function RecentArtifactCalls() {
  const { api } = useSession();
  const { conversations, users = [] } = useWorkspaceData();
  const duplicateNames = useMemo(() => duplicateParticipantNames(users), [users]);
  const [calls, setCalls] = useState<CallSummary[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [media, setMedia] = useState("all");
  const generation = useRef(0);
  const load = useCallback(async (next: string | null = null) => {
    const request = ++generation.current;
    setLoading(true); setError(null);
    try {
      const result = await api.calls({ scope: "recent", limit: 25, cursor: next });
      if (request !== generation.current) return;
      setCalls(current => next ? [...current, ...result.data.filter(item => !current.some(existing => existing.id === item.id))] : result.data);
      setCursor(result.page.has_more ? result.page.next_cursor : null);
    } catch (reason) {
      if (request === generation.current) { setError(errorText(reason)); setCalls([]); setCursor(null); }
    } finally { if (request === generation.current) setLoading(false); }
  }, [api]);
  useEffect(() => {
    void load();
    const refresh = () => void load();
    window.addEventListener("focus", refresh);
    return () => { generation.current += 1; window.removeEventListener("focus", refresh); };
  }, [load]);
  const title = (call: CallSummary) => {
    const conversation = conversations.find(item => item.id === call.conversation_id);
    return conversation ? conversationTitle(conversation) : "Conversation unavailable";
  };
  const visible = calls.filter(call => (media === "all" || call.media_kind === media) && title(call).toLocaleLowerCase().includes(search.trim().toLocaleLowerCase()));
  return <section className="artifacts-library" aria-labelledby="artifacts-library-heading">
    <div className="artifacts-library-heading"><div><h2 id="artifacts-library-heading">Recent calls</h2><p>Open a call to see its recordings, saved transcripts, and selected-quote summaries. Recording availability is checked when you open it.</p></div><button className="button ghost" type="button" disabled={loading} onClick={() => void load()}>Refresh</button></div>
    <div className="artifacts-filters"><label className="field">Find a conversation<input type="search" value={search} onChange={event => setSearch(event.currentTarget.value)} placeholder="Search loaded calls" /></label><label className="field">Call type<select value={media} onChange={event => setMedia(event.currentTarget.value)}><option value="all">All calls</option><option value="video">Video</option><option value="audio">Audio</option></select></label></div>
    {error && <div className="inline-notice error" role="alert"><p>{error}</p><button className="button ghost" type="button" onClick={() => void load()}>Try again</button></div>}
    {loading && <p role="status">Loading recent calls…</p>}
    {!loading && !error && visible.length === 0 && <div className="surface-empty"><AppIcon name="file" /><strong>{calls.length ? "No matching loaded calls" : "No recent calls"}</strong><p>{calls.length ? "Try another conversation name or call type." : "Completed call sessions appear here. Recordings require an enabled provider and participant consent."}</p><Link className="button ghost" to="/app/calls">Go to Calls</Link></div>}
    <ol className="artifacts-call-list" aria-label="Recent calls for saved content">{visible.map(call => {
      const starter = users.find(user => user.id === call.started_by_user_id);
      return <li key={call.id} className="surface-card"><div><h3>{title(call)}</h3><p><time dateTime={call.started_at}>{formatDateTime(call.started_at)}</time> · {call.media_kind === "audio" ? "Audio" : "Video"} call</p><p>Started by {starter ? participantIdentifier(starter, duplicateNames) : "Member unavailable"}</p><span className="status-pill neutral">{call.status === "ended" ? "Ended" : call.status === "ending" ? "Ending" : "Active"}</span></div><Link className="button ghost" aria-label={`View saved content for ${title(call)} at ${formatDateTime(call.started_at)}`} to={`/app/artifacts?${new URLSearchParams({ conversation: call.conversation_id, call: call.id }).toString()}`}>View saved content</Link></li>;
    })}</ol>
    {cursor && <button className="button ghost" type="button" disabled={loading} onClick={() => void load(cursor)}>Load older calls</button>}
    <p className="artifacts-coverage">Search and filters apply to loaded calls. Workspace search can retrieve other authorized recordings and transcripts.</p>
  </section>;
}
