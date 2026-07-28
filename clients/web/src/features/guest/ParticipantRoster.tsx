import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { ConversationMembership } from "../../types";
import { initials } from "../../lib/format";
import {
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";

export function ParticipantRoster({
  members,
  onlineUserIds,
  currentUserId,
  presenceKnown = true,
  compact = false
}: {
  members: ConversationMembership[];
  onlineUserIds: ReadonlySet<string>;
  currentUserId: string;
  presenceKnown?: boolean;
  compact?: boolean;
}) {
  const [expanded, setExpanded] = useState(!compact);
  const compactToggleRef = useRef<HTMLButtonElement | null>(null);
  const headingRef = useRef<HTMLHeadingElement | null>(null);
  const compactToggleFocusedRef = useRef(false);
  const participants = useMemo(() => {
    const uniqueMembers = new Map<string, ConversationMembership>();
    for (const member of members) uniqueMembers.set(member.user.id, member);

    return [...uniqueMembers.values()].sort((left, right) => {
      const leftIsCurrent = left.user.id === currentUserId;
      const rightIsCurrent = right.user.id === currentUserId;
      if (leftIsCurrent !== rightIsCurrent) return leftIsCurrent ? -1 : 1;

      const leftIsOnline = presenceKnown && onlineUserIds.has(left.user.id);
      const rightIsOnline = presenceKnown && onlineUserIds.has(right.user.id);
      if (leftIsOnline !== rightIsOnline) return leftIsOnline ? -1 : 1;

      return left.user.display_name.localeCompare(right.user.display_name);
    });
  }, [currentUserId, members, onlineUserIds, presenceKnown]);

  const duplicateDisplayNames = useMemo(() => {
    return duplicateParticipantNames(participants.map(({ user }) => user));
  }, [participants]);

  const onlineCount = presenceKnown
    ? participants.filter(({ user }) => onlineUserIds.has(user.id)).length
    : 0;
  const presenceSummary = presenceKnown
    ? `${onlineCount} online · ${participants.length} total`
    : `Presence unknown · ${participants.length} total`;

  useEffect(() => {
    setExpanded(!compact);
  }, [compact]);

  useEffect(() => {
    const clearToggleFocus = (event: FocusEvent) => {
      if (event.target !== compactToggleRef.current) {
        compactToggleFocusedRef.current = false;
      }
    };
    document.addEventListener("focusin", clearToggleFocus);
    return () => document.removeEventListener("focusin", clearToggleFocus);
  }, []);

  useLayoutEffect(() => {
    if (!compact && compactToggleFocusedRef.current) {
      compactToggleFocusedRef.current = false;
      headingRef.current?.focus();
    }
  }, [compact]);

  const participantList = (
    <ul
      id={compact ? "guest-participant-list" : undefined}
      aria-label="Room participants"
      tabIndex={participants.length > 4 ? 0 : undefined}
    >
      {participants.map((member) => {
        const isCurrent = member.user.id === currentUserId;
        const isOnline = presenceKnown && onlineUserIds.has(member.user.id);
        const identifier = participantIdentifier(
          member.user,
          duplicateDisplayNames
        );
        const disambiguatorPrefix = `${member.user.display_name} · #`;
        const disambiguator = identifier.startsWith(disambiguatorPrefix)
          ? identifier.slice(disambiguatorPrefix.length)
          : null;
        return (
          <li key={member.user.id}>
            <span className="avatar small" aria-hidden="true">
              {initials(member.user.display_name)}
            </span>
            <span className="guest-participant-identity">
              <strong>
                {member.user.display_name}
                {disambiguator && (
                  <span
                    className="guest-participant-disambiguator"
                    aria-label={`participant identifier ${disambiguator}`}
                  >
                    {" "}· #{disambiguator}
                  </span>
                )}
                {isCurrent && <span className="guest-participant-you"> (you)</span>}
              </strong>
              <small>
                <span
                  className={`guest-participant-presence ${
                    presenceKnown ? (isOnline ? "online" : "offline") : "unknown"
                  }`}
                  aria-hidden="true"
                />
                {presenceKnown ? (isOnline ? "Online" : "Offline") : "Presence unknown"}
                {member.user.account_type === "guest" && " · Guest"}
              </small>
            </span>
          </li>
        );
      })}
    </ul>
  );

  return (
    <section
      className={`guest-participant-roster${compact ? " compact" : ""}${
        participants.length > 4 ? " is-scrollable" : ""
      }`}
      aria-labelledby={compact ? undefined : "guest-participant-title"}
      aria-label={compact ? "Participants" : undefined}
    >
      {compact ? (
        <>
          <button
            ref={compactToggleRef}
            className="guest-participant-toggle"
            type="button"
            aria-expanded={expanded}
            aria-controls="guest-participant-list"
            onFocus={() => {
              compactToggleFocusedRef.current = true;
            }}
            onClick={() => setExpanded((current) => !current)}
          >
            <strong>Participants</strong>
            <span aria-live="polite">{presenceSummary}</span>
          </button>
          {expanded && participantList}
        </>
      ) : (
        <>
          <div className="guest-participant-heading">
            <h2 ref={headingRef} id="guest-participant-title" tabIndex={-1}>
              Participants
            </h2>
            <span aria-live="polite">{presenceSummary}</span>
          </div>
          {participantList}
        </>
      )}
    </section>
  );
}
