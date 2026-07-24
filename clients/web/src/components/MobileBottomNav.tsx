import type { ReactNode } from "react";
import { NavLink } from "react-router";

type MemberDestination = {
  label: "Inbox" | "Calls" | "Directory" | "Files" | "You";
  path: string;
  icon: ReactNode;
};

export const memberDestinations: MemberDestination[] = [
  {
    label: "Inbox",
    path: "/app",
    icon: <path d="M4 5.5h16v11H8l-4 3v-14Z" />
  },
  {
    label: "Calls",
    path: "/app/calls",
    icon: <path d="M7.2 3.5 10 8 8.4 9.7a13 13 0 0 0 5.9 5.9L16 14l4.5 2.8-.8 3.2c-.2.8-1 1.3-1.8 1.2A17.6 17.6 0 0 1 2.8 6.1C2.7 5.3 3.2 4.5 4 4.3l3.2-.8Z" />
  },
  {
    label: "Directory",
    path: "/app/directory",
    icon: (
      <>
        <circle cx="9" cy="8" r="3" />
        <path d="M3.5 19c.4-4 2.2-6 5.5-6s5.1 2 5.5 6M16 6h5M16 10h5M17 14h4" />
      </>
    )
  },
  {
    label: "Files",
    path: "/app/files",
    icon: <path d="M5 3.5h9l5 5V21H5V3.5Zm9 0V9h5M8 13h8M8 17h8" />
  },
  {
    label: "You",
    path: "/app/you",
    icon: (
      <>
        <circle cx="12" cy="8" r="4" />
        <path d="M4.5 21c.5-5 3-7.5 7.5-7.5s7 2.5 7.5 7.5" />
      </>
    )
  }
];

export function MemberAreaLinks({ mobile = false }: { mobile?: boolean }) {
  return (
    <>
      {memberDestinations.map(({ icon, label, path }) => (
        <NavLink key={path} to={path} end={path === "/app"}>
          {mobile && (
            <svg
              className="member-nav-icon"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth="1.8"
              aria-hidden="true"
            >
              {icon}
            </svg>
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
