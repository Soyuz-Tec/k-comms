import { NavLink } from "react-router";
import { AppIcon, type AppIconName } from "./AppIcon";

type MemberDestination = {
  label: "Inbox" | "Calls" | "Whiteboard" | "Directory" | "Files" | "You";
  /** Wording the mobile top bar uses for this area; the nav keeps the shorter label. */
  title: string;
  path: string;
  icon: AppIconName;
  group: "Communicate" | "Collaborate" | "Personal";
  mobilePrimary: boolean;
};

export const memberDestinations: MemberDestination[] = [
  {
    label: "Inbox",
    title: "Inbox",
    path: "/app/",
    icon: "message",
    group: "Communicate",
    mobilePrimary: true
  },
  {
    label: "Calls",
    title: "Calls",
    path: "/app/calls",
    icon: "phone",
    group: "Communicate",
    mobilePrimary: true
  },
  {
    label: "Whiteboard",
    title: "Whiteboard",
    path: "/app/whiteboard",
    icon: "whiteboard",
    group: "Collaborate",
    mobilePrimary: false
  },
  {
    label: "Directory",
    title: "Directory",
    path: "/app/directory",
    icon: "contact",
    group: "Collaborate",
    mobilePrimary: true
  },
  {
    label: "Files",
    title: "Files",
    path: "/app/files",
    icon: "file",
    group: "Collaborate",
    mobilePrimary: true
  },
  {
    label: "You",
    title: "Profile and settings",
    path: "/app/you",
    icon: "user",
    group: "Personal",
    mobilePrimary: true
  }
];

/*
 * Areas reachable from the More drawer rather than the bottom bar. They still
 * need a top-bar title because mobile has no other place to say where you are.
 */
const privilegedAreaTitles: ReadonlyArray<readonly [string, string]> = [
  ["/admin", "Workspace administration"],
  ["/ops", "Service operations"]
];

function normalizePath(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  return trimmed === "" ? "/" : trimmed;
}

/**
 * Title for the current route, shown by the mobile top bar. Mobile drops the
 * in-page heading, so this is the only place the surface names itself.
 */
export function memberAreaTitle(pathname: string): string {
  const current = normalizePath(pathname);
  const known = [
    ...memberDestinations.map(({ path, title }) => [normalizePath(path), title] as const),
    ...privilegedAreaTitles
  ];
  const exact = known.find(([path]) => path === current);
  if (exact) return exact[1];
  const nested = known
    .filter(([path]) => path !== "/app" && current.startsWith(`${path}/`))
    .sort((left, right) => right[0].length - left[0].length)[0];
  return nested ? nested[1] : "K-Comms";
}

type MemberAreaLinksVariant = "all" | "grouped" | "mobile-primary" | "mobile-more";

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

  const destinations = memberDestinations.filter(({ mobilePrimary }) => {
    if (variant === "mobile-primary") return mobilePrimary;
    if (variant === "mobile-more") return !mobilePrimary;
    return true;
  });

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
