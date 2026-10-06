import { useLayoutEffect, useMemo, useRef } from "react";
import { Link } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import { contentLibrary } from "../../components/contentLibrary";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { UnifiedSearchPanel } from "../chat/UnifiedSearchPanel";
import "./ContentPage.css";

const descriptions: Record<string, string> = {
  Files: "Attachments shared in your conversations",
  "Shared documents": "Notes and plans you write together",
  Whiteboard: "Conversation canvases and diagrams",
  Recordings: "Saved calls, transcripts and summaries",
  "Saved items": "Messages you bookmarked for later"
};

export function ContentPage() {
  const { api, session } = useSession();
  const { conversations } = useWorkspaceData();
  const main = useRef<HTMLElement | null>(null);
  // Mobile shortcuts can be near the bottom of You; open the hub at its heading.
  useLayoutEffect(() => { main.current?.scrollIntoView({ block: "start", behavior: "instant" }); }, []);
  const conversationScope = conversations.map(conversation => conversation.id).sort().join(",");
  const identityGeneration = useMemo(() => crypto.randomUUID(), [api, conversationScope,
    session?.access_token, session?.refresh_token, session?.tenant.id, session?.tenant.status,
    session?.user.id, session?.user.tenant_id, session?.user.role, session?.user.status,
    session?.user.version, session?.user.account_type, session?.user.access_scope,
    session?.device.id, session?.device.user_id, session?.device.revoked_at
  ]);
  if (!session) return null;

  return <main ref={main} className="page-shell content-page" id="main-content">
    <SurfaceHeader title="Content" description="Find and revisit work shared across your conversations." />
    <nav className="content-library" aria-label="Browse content">
      {contentLibrary.map(({ label, path, icon }) => <Link key={path} to={path} className="content-library-link">
        <AppIcon name={icon} className="content-library-icon" />
        <span><strong>{label}</strong><span className="content-library-description">{descriptions[label]}</span></span>
        <AppIcon name="arrowUpRight" className="content-library-arrow" />
      </Link>)}
    </nav>
    <UnifiedSearchPanel key={identityGeneration} api={api} conversations={conversations} inline onClose={() => undefined} />
  </main>;
}
