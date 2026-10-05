import { Link, useSearchParams } from "react-router";
import { useSession } from "../../app/session";
import { MeetingArtifactsPanel } from "./MeetingArtifactsPanel";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function MeetingArtifactsPage() {
  const { api } = useSession();
  const [params] = useSearchParams();
  const conversationId = params.get("conversation") || "";
  const callId = params.get("call") || "";
  const artifactId = params.get("artifact") || undefined;
  const valid = uuid.test(conversationId) && uuid.test(callId) && (!artifactId || uuid.test(artifactId));
  return <main id="main-content" className="member-page">
    <header className="member-page-heading"><div><h1>Meeting recordings and transcripts</h1><p>Access follows your current conversation membership and the workspace retention policy.</p></div><Link to="/app/calls">Calls</Link></header>
    {valid ? <>
      <Link to={`/app/?conversation=${encodeURIComponent(conversationId)}`}>Open conversation</Link>
      <MeetingArtifactsPanel api={api} conversationId={conversationId} callId={callId} artifactId={artifactId} />
    </> : <p role="alert">This recording link is incomplete. Open a recording from call history or workspace search.</p>}
  </main>;
}
