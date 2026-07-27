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

export function MemberAreaLinks({ mobile = false }: { mobile?: boolean }) {
  return (
    <>
      {memberDestinations.map(({ icon, label, path }) => (
        <NavLink key={path} to={path} end={path === "/app"}>
          {mobile && (
            <AppIcon
              name={icon}
              className="member-nav-icon"
            />
          )}
          <span>{label}</span>
        </NavLink>
      ))}
    </>
  );
}

export function MobileBottomNav() {
  return (
    <nav className="mobile-product-nav member-bottom-nav" aria-label="Mobile product areas">
      <MemberAreaLinks mobile />
    </nav>
  );
}
