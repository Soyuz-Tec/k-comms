import { render, screen, within } from "@testing-library/react";
import type { ReactNode } from "react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { YouPage } from "./YouPage";

const harness = vi.hoisted(() => ({
  role: "member",
  accessScope: "workspace" as "workspace" | "conversation_only",
  platformRole: null as string | null,
  platformRoleExpiresAt: null as string | null
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    session: {
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        role: harness.role,
        account_type: "human",
        access_scope: harness.accessScope,
        status: "active",
        platform_role: harness.platformRole,
        platform_role_expires_at: harness.platformRoleExpiresAt
      }
    }
  })
}));

vi.mock("../settings/SettingsPage", () => ({
  SettingsPage: ({ roleTools }: { roleTools?: ReactNode }) => (
    <main id="main-content">
      <h1>You</h1>
      <nav aria-label="Profile and settings sections">
        <button type="button" role="tab">Profile</button>
        <button type="button" role="tab">Security</button>
        <button type="button" role="tab">Notifications</button>
      </nav>
      {roleTools}
    </main>
  )
}));

describe("YouPage", () => {
  it("keeps personal settings while hiding every admin shortcut for a limited legacy owner", () => {
    harness.role = "owner";
    harness.accessScope = "conversation_only";
    harness.platformRole = null;
    harness.platformRoleExpiresAt = null;
    render(<MemoryRouter><YouPage /></MemoryRouter>);
    expect(screen.getByRole("heading", { name: "You" })).toBeVisible();
    expect(screen.getByRole("tab", { name: "Profile" })).toBeVisible();
    expect(screen.queryByRole("link", { name: /People & invitations/i })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /Safety review/i })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /Workspace administration/i })).not.toBeInTheDocument();
    expect(screen.queryByRole("navigation", { name: "Administration and operations" })).not.toBeInTheDocument();
  });

  it("keeps role tools out of the member profile", () => {
    harness.role = "member";
    harness.accessScope = "workspace";
    harness.platformRole = null;
    harness.platformRoleExpiresAt = null;
    render(<MemoryRouter><YouPage /></MemoryRouter>);

    expect(screen.getByRole("heading", { name: "You" })).toBeVisible();
    expect(screen.queryByRole("navigation", { name: "Administration and operations" })).not.toBeInTheDocument();
    const sections = screen.getByRole("navigation", { name: "Profile and settings sections" });
    expect(
      screen.getByRole("heading", { name: "You" }).compareDocumentPosition(sections)
      & Node.DOCUMENT_POSITION_FOLLOWING
    ).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Profile" })).toBeVisible();
    expect(screen.getByRole("tab", { name: "Security" })).toBeVisible();
    expect(screen.getByRole("tab", { name: "Notifications" })).toBeVisible();
    expect(sections).toContainElement(screen.getByRole("tab", { name: "Profile" }));
    const workspace = screen.getByRole("navigation", { name: "Workspace" });
    expect(workspace).toContainElement(screen.getByRole("link", { name: "Meetings" }));
    expect(screen.getByRole("link", { name: "Meetings" })).toHaveAttribute("href", "/app/meetings");
    expect(workspace).toContainElement(screen.getByRole("link", { name: "Saved items" }));
    expect(screen.getByRole("link", { name: "Saved items" })).toHaveAttribute("href", "/app/saved");
    expect(workspace).toContainElement(screen.getByRole("link", { name: "Shared documents" }));
    expect(within(workspace).getByRole("link", { name: "Phone" })).toHaveAttribute("href", "/app/calls/phone");
    expect(within(workspace).getByRole("link", { name: "Recordings" })).toHaveAttribute("href", "/app/artifacts");
    expect(within(workspace).getByRole("link", { name: "Private rooms" })).toHaveAttribute("href", "/app/private");
  });

  it("provides direct role-gated people, safety and operations entries", () => {
    harness.role = "owner";
    harness.accessScope = "workspace";
    harness.platformRole = "platform_operator";
    harness.platformRoleExpiresAt = "2099-01-01T00:00:00Z";
    render(<MemoryRouter><YouPage /></MemoryRouter>);

    expect(screen.getByRole("link", { name: /People & invitations/i })).toHaveAttribute(
      "href",
      "/admin?section=people"
    );
    expect(screen.getByRole("link", { name: /Safety review/i })).toHaveAttribute(
      "href",
      "/admin?section=safety"
    );
    expect(screen.getByRole("link", { name: /Workspace administration/i })).toHaveAttribute(
      "href",
      "/admin"
    );
    expect(screen.getByRole("link", { name: /Service operations/i })).toHaveAttribute(
      "href",
      "/ops"
    );
    const administration = screen.getByRole("navigation", { name: "Administration and operations" });
    expect(within(administration).getByRole("link", { name: "Workspace administration" })).toBeVisible();
    expect(within(administration).queryByRole("link", { name: "Whiteboard" })).not.toBeInTheDocument();
    expect(within(screen.getByRole("navigation", { name: "Workspace" })).queryByRole("link", { name: "Workspace administration" })).not.toBeInTheDocument();
  });
});
