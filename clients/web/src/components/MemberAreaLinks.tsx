import { NavLink } from "react-router";
import { AppIcon, type AppIconName } from "./AppIcon";

type MemberDestination = {
  label: "Inbox" | "Calls" | "Whiteboard" | "Directory" | "Files" | "You";
  path: string;
  icon: AppIconName;
  group: "Communicate" | "Collaborate" | "Personal";
  /**
   * Phones show exactly five destinations and have no overflow drawer, so this
   * flag is a hard budget rather than a preference.
   *
   * Whiteboard is the one that gives up a place, and it costs nothing: the
   * drawer put it two taps from the inbox, the You screen puts it two taps from
   * the inbox, and inside a conversation Canvas is one tap in the header sheet.
   * Directory and Files keep theirs because member-ia.spec.ts encodes a
   * two-action budget through each of them — Directory to start a direct
   * message, Files to reach a shared file's source message — and a tab is what
   * makes the first of those two actions possible.
   */
  mobilePrimary: boolean;
};

export const memberDestinations: MemberDestination[] = [
  {
    label: "Inbox",
    path: "/app/",
    icon: "message",
    group: "Communicate",
    mobilePrimary: true
  },
  {
    label: "Calls",
    path: "/app/calls",
    icon: "phone",
    group: "Communicate",
    mobilePrimary: true
  },
  {
    label: "Whiteboard",
    path: "/app/whiteboard",
    icon: "whiteboard",
    group: "Collaborate",
    mobilePrimary: false
  },
  {
    label: "Directory",
    path: "/app/directory",
    icon: "contact",
    group: "Collaborate",
    mobilePrimary: true
  },
  {
    label: "Files",
    path: "/app/files",
    icon: "file",
    group: "Collaborate",
    mobilePrimary: true
  },
  {
    label: "You",
    path: "/app/you",
    icon: "user",
    group: "Personal",
    mobilePrimary: true
  }
];

type MemberAreaLinksVariant = "all" | "grouped" | "mobile-primary";

export function MemberAreaLinks({
  compact = false,
  variant = "all"
}: {
  compact?: boolean;
  variant?: MemberAreaLinksVariant;
}) {
  if (variant === "grouped") {
    return (
      <>
        {(["Communicate", "Collaborate", "Personal"] as const).map((group) => (
          <section className="member-nav-group" key={group} aria-labelledby={`member-nav-${group.toLowerCase()}`}>
            <span className="member-nav-group-label" id={`member-nav-${group.toLowerCase()}`}>{group}</span>
            {memberDestinations
              .filter((destination) => destination.group === group)
              .map((destination) => <MemberAreaLink key={destination.path} {...destination} compact={compact} />)}
          </section>
        ))}
      </>
    );
  }

  const destinations = variant === "mobile-primary"
    ? memberDestinations.filter(({ mobilePrimary }) => mobilePrimary)
    : memberDestinations;

  return (
    <>
      {destinations.map((destination) => (
        <MemberAreaLink key={destination.path} {...destination} compact={compact} />
      ))}
    </>
  );
}

function MemberAreaLink({
  compact,
  icon,
  label,
  path
}: MemberDestination & { compact: boolean }) {
  return (
    <NavLink
      to={path}
      end={path === "/app/"}
      aria-label={compact ? label : undefined}
      title={compact ? label : undefined}
    >
      <AppIcon name={icon} className="member-nav-icon" />
      <span className={compact ? "visually-hidden" : undefined}>{label}</span>
    </NavLink>
  );
}
