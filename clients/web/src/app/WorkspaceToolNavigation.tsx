import { NavLink, useLocation } from "react-router";
import { AppIcon } from "../components/AppIcon";
import { memberDestinations } from "../components/MemberAreaLinks";

// Primary areas belong to the activity rail; this list holds their tools.
const tools = memberDestinations.filter(({ label }) =>
  ["Private rooms", "Phone", "Recordings", "Whiteboard", "Saved items"].includes(label)
);

export function WorkspaceToolNavigation({ compact }: { compact: boolean }) {
  const { pathname } = useLocation();
  const related = pathname.startsWith("/app/calls") || pathname.startsWith("/app/artifacts")
    ? { label: "Call tools", names: ["Phone", "Recordings"] }
    : pathname.startsWith("/app/meetings")
      ? { label: "Meeting content", names: ["Recordings"] }
      : pathname.startsWith("/app/documents") || pathname.startsWith("/app/whiteboard")
        ? { label: "Document tools", names: ["Whiteboard"] }
        : pathname === "/app" || pathname === "/app/" || pathname.startsWith("/app/private") || pathname.startsWith("/app/saved")
          ? { label: "Conversation tools", names: ["Private rooms", "Saved items"] }
          : { label: "Workspace tools", names: [] };
  const groups = related.names.length
    ? [
        { label: related.label, items: tools.filter(({ label }) => related.names.includes(label)) },
        { label: "Other tools", items: tools.filter(({ label }) => !related.names.includes(label)) }
      ]
    : [{ label: related.label, items: tools }];

  return <nav className="workspace-sidebar-nav" aria-label="Workspace tools">
    {groups.map(({ label, items }) => <section className="member-nav-group" key={label} aria-label={label}>
      <span className="member-nav-group-label" aria-hidden="true">{label}</span>
      {items.map(({ path, icon, label: name }) => <NavLink key={path} to={path}
        aria-label={compact ? name : undefined} title={compact ? name : undefined}>
        <AppIcon name={icon} className="member-nav-icon" />
        <span className={compact ? "visually-hidden" : undefined}>{name}</span>
      </NavLink>)}
    </section>)}
  </nav>;
}
