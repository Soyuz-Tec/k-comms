import { NavLink } from "react-router";
import { AppIcon, type AppIconName } from "./AppIcon";

type MemberDestination = {
  label: "Inbox" | "Calls" | "Directory" | "Files" | "You";
  path: string;
  icon: AppIconName;
};

export const memberDestinations: MemberDestination[] = [
  {
    label: "Inbox",
    path: "/app",
    icon: "message"
  },
  {
    label: "Calls",
    path: "/app/calls",
    icon: "phone"
  },
  {
    label: "Directory",
    path: "/app/directory",
    icon: "contact"
  },
  {
    label: "Files",
    path: "/app/files",
    icon: "file"
  },
  {
    label: "You",
    path: "/app/you",
    icon: "user"
  }
];

export function MemberAreaLinks({ compact = false }: { compact?: boolean }) {
  return (
    <>
      {memberDestinations.map(({ icon, label, path }) => {
        const targetPath = path === "/app" ? "/app/" : path;
        return (
          <NavLink
            key={path}
            to={targetPath}
            end={path === "/app"}
            aria-label={compact ? label : undefined}
            title={compact ? label : undefined}
          >
            {compact && <AppIcon name={icon} className="member-nav-icon" />}
            <span className={compact ? "visually-hidden" : undefined}>{label}</span>
          </NavLink>
        );
      })}
    </>
  );
}
