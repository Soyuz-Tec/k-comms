import { useEffect, useState } from "react";
import { Link, useLocation } from "react-router";
import { canAccessWorkspaceAdmin, canOperate } from "../lib/roles";
import type { User } from "../types";
import { AppIcon, type AppIconName } from "./AppIcon";
import { AvatarBadge } from "./AvatarBadge";
import "./DesktopActivityRail.css";

interface Shortcut {
  label: string;
  path: string;
  icon: AppIconName;
  exact?: boolean;
}

const shortcuts: Shortcut[] = [
  { label: "Inbox", path: "/app/", icon: "messages", exact: true },
  { label: "Calls", path: "/app/calls", icon: "phone", exact: true },
  { label: "Meetings", path: "/app/meetings", icon: "clock" },
  { label: "Shared documents", path: "/app/documents", icon: "file" },
  { label: "Files", path: "/app/files", icon: "paperclip" },
  { label: "Directory", path: "/app/directory", icon: "contact" }
];

/** Persistent desktop shortcuts; the shell owns mounting and positioning. */
export function DesktopActivityRail({ user }: { user: User }) {
  const location = useLocation();
  const [authorityRevision, refreshAuthority] = useState(0);
  useEffect(() => {
    const remaining = Date.parse(user.platform_role_expires_at ?? "") - Date.now();
    if (!Number.isFinite(remaining) || remaining <= 0) return;
    // Withdraw a temporary operations shortcut even when the desktop is idle.
    const timer = window.setTimeout(
      () => refreshAuthority((revision) => revision + 1),
      Math.min(remaining + 1, 2_147_483_647)
    );
    return () => window.clearTimeout(timer);
  }, [user.platform_role_expires_at, authorityRevision]);

  const roleShortcuts: Shortcut[] = [];
  if (canAccessWorkspaceAdmin(user)) {
    roleShortcuts.push({ label: "Workspace administration", path: "/admin", icon: "settings" });
  }
  if (canOperate(user.platform_role, user.platform_role_expires_at)) {
    roleShortcuts.push({ label: "Service operations", path: "/ops", icon: "activity" });
  }

  function current(shortcut: Pick<Shortcut, "path" | "exact">) {
    const pathname = location.pathname.replace(/\/+$/, "");
    const path = shortcut.path.replace(/\/+$/, "");
    return pathname === path || (!shortcut.exact && pathname.startsWith(`${path}/`));
  }

  function shortcutLink(shortcut: Shortcut) {
    const selected = current(shortcut);
    // Reopening the current document area must retain its conversation/document.
    const to = selected && shortcut.path === "/app/documents"
      ? { pathname: location.pathname, search: location.search, hash: location.hash }
      : shortcut.path;
    return <Link key={shortcut.path} className="desktop-activity-link" to={to}
      aria-label={`Open ${shortcut.label}`} aria-current={selected ? "page" : undefined}
      title={shortcut.label}>
      <AppIcon name={shortcut.icon} />
    </Link>;
  }

  return <nav className="desktop-activity-rail" aria-label="Workspace shortcuts">
    <div className="desktop-activity-shortcuts">{shortcuts.map(shortcutLink)}</div>
    {roleShortcuts.length > 0 && <div className="desktop-activity-role-shortcuts">
      {roleShortcuts.map(shortcutLink)}
    </div>}
    <div className="desktop-activity-identity-slot">
      <Link className="desktop-activity-link desktop-activity-identity" to="/app/you"
        aria-label={`Open You (${user.display_name})`} title={`You (${user.display_name})`}
        aria-current={current({ path: "/app/you" }) ? "page" : undefined}>
        <AvatarBadge name={user.display_name} avatarUrl={user.avatar_url} size="small" />
      </Link>
    </div>
  </nav>;
}
