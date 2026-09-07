import { useEffect, useId, useState } from "react";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router";
import { AppIcon, type AppIconName } from "../components/AppIcon";
import { memberDestinations } from "../components/MemberAreaLinks";
import { useModalDialog } from "../components/useModalDialog";
import { conversationTitle } from "../lib/format";
import { canAccessAdmin, canOperate } from "../lib/roles";
import { conversationParticipantIdentifier, duplicateDirectConversationNames, duplicateParticipantNames, participantIdentifier } from "../lib/participantIdentity";
import type { Conversation, Session } from "../types";
import "./WorkspaceSwitcher.css";

interface Destination {
  id: string;
  label: string;
  detail: string;
  path: string;
  icon: AppIconName;
}

export function workspaceDestinations(session: Session, conversations: Conversation[]): Destination[] {
  const activeConversations = conversations.filter((conversation) => !conversation.archived_at);
  const duplicateDirectNames = duplicateDirectConversationNames(activeConversations);
  const duplicateRoomNames = duplicateParticipantNames(activeConversations.filter(({ kind }) => kind !== "direct")
    .map((conversation) => ({ id: conversation.id, display_name: conversationTitle(conversation) })));
  const areas: Destination[] = memberDestinations.map((destination) => ({
    id: destination.path, label: destination.label, detail: "Workspace",
    path: destination.path, icon: destination.icon
  }));
  if (canAccessAdmin(session.user.role)) areas.push({
    id: "admin", label: "Workspace administration", detail: "Role tools", path: "/admin", icon: "settings"
  });
  if (canOperate(session.user.platform_role, session.user.platform_role_expires_at)) areas.push({
    id: "ops", label: "Service operations", detail: "Role tools", path: "/ops", icon: "activity"
  });
  return [...areas, ...activeConversations.map((conversation): Destination => ({
    id: conversation.id, label: conversation.kind === "direct"
      ? conversationParticipantIdentifier(conversation, duplicateDirectNames)
      : participantIdentifier({ id: conversation.id, display_name: conversationTitle(conversation) }, duplicateRoomNames),
    detail: conversation.kind === "direct" ? "Direct message" : conversation.kind === "channel" ? "Channel" : "Group conversation",
    path: `/app/?conversation=${encodeURIComponent(conversation.id)}`,
    icon: conversation.kind === "channel" ? "hash" : conversation.kind === "direct" ? "message" : "users"
  }))];
}

/** Navigation over the already-authorized workspace snapshot; never a new search API. */
export function WorkspaceSwitcher({ session, conversations, onClose }: {
  session: Session;
  conversations: Conversation[];
  onClose: () => void;
}) {
  const navigate = useNavigate();
  const dialogRef = useModalDialog(onClose);
  const id = useId();
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);
  const [, refreshAuthority] = useState(0);
  useEffect(() => {
    const remaining = Date.parse(session.user.platform_role_expires_at ?? "") - Date.now();
    if (!Number.isFinite(remaining) || remaining < 0) return;
    const timer = window.setTimeout(() => refreshAuthority((value) => value + 1), Math.min(remaining + 1, 2_147_483_647));
    return () => window.clearTimeout(timer);
  }, [session.user.platform_role_expires_at]);
  const options = workspaceDestinations(session, conversations);
  const matches = options.filter(({ label, detail }) => `${label} ${detail}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()));
  const visible = matches.slice(0, 12);
  const active = Math.min(activeIndex, visible.length - 1);
  useEffect(() => {
    document.getElementById(`${id}-option-${active}`)?.scrollIntoView?.({ block: "nearest" });
  }, [id, active]);
  function select(destination: Destination) {
    onClose();
    navigate(destination.path);
  }
  return createPortal(
    <div className="workspace-switcher-backdrop" onPointerDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section ref={dialogRef} className="workspace-switcher" role="dialog" aria-modal="true" aria-labelledby={`${id}-title`}>
        <header>
          <div><h2 id={`${id}-title`}>Go to…</h2><p>Conversations and workspace tools</p></div>
          <button className="icon-button" type="button" aria-label="Close workspace switcher" onClick={onClose}><AppIcon name="x" /></button>
        </header>
        <div className="workspace-switcher-search">
          <AppIcon name="search" />
          <input data-initial-focus role="combobox" aria-label="Find a conversation or screen" aria-autocomplete="list"
            aria-expanded="true" aria-controls={`${id}-results`} aria-activedescendant={active >= 0 ? `${id}-option-${active}` : undefined}
            placeholder="Where would you like to go?" value={query}
            onChange={(event) => { setQuery(event.target.value); setActiveIndex(0); }}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing || event.keyCode === 229) return;
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                event.preventDefault();
                if (visible.length) setActiveIndex((active + (event.key === "ArrowDown" ? 1 : -1) + visible.length) % visible.length);
              } else if (event.key === "Enter" && visible[active]) {
                event.preventDefault();
                select(visible[active]);
              }
            }} />
        </div>
        <div className="workspace-switcher-results" role="listbox" id={`${id}-results`} aria-label="Destinations">
          {visible.map((destination, index) => (
            <div key={destination.id} id={`${id}-option-${index}`} role="option" aria-selected={active === index}
              className="workspace-switcher-option" onPointerMove={() => setActiveIndex(index)} onClick={() => select(destination)}>
              <AppIcon name={destination.icon} />
              <span><strong>{destination.label}</strong><small>{destination.detail}</small></span>
              <AppIcon name="arrowUpRight" />
            </div>
          ))}
        </div>
        <footer>
          <span role="status">{matches.length === 0 ? "No matching destination. Try another name." : matches.length > 12 ? `${matches.length} matches · keep typing to narrow results` : `${matches.length} destinations`}</span>
          <span className="workspace-switcher-hint">Arrow keys to choose · Enter to open · Esc to close</span>
        </footer>
      </section>
    </div>, document.body
  );
}
