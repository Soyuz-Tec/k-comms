import { useMemo } from "react";
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
  presenceKnown = true
}: {
  members: ConversationMembership[];
  onlineUserIds: ReadonlySet<string>;
  currentUserId: string;
  presenceKnown?: boolean;
}) {
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

  return (
    <section className="guest-participant-roster" aria-labelledby="guest-participant-title">
      <div className="guest-participant-heading">
        <h2 id="guest-participant-title">Participants</h2>
        <span aria-live="polite">
          {presenceKnown
            ? `${onlineCount} online · ${participants.length} total`
            : `Presence unknown · ${participants.length} total`}
        </span>
      </div>
      <ul aria-label="Room participants" tabIndex={0}>
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
    </section>
  );
}
