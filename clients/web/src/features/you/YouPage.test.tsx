import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { YouPage } from "./YouPage";

const harness = vi.hoisted(() => ({
  role: "member",
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
        status: "active",
        platform_role: harness.platformRole,
        platform_role_expires_at: harness.platformRoleExpiresAt
      }
    }
  })
}));

vi.mock("../settings/SettingsPage", () => ({
  SettingsPage: () => <main id="main-content"><h1>Profile and settings</h1></main>
}));

describe("YouPage", () => {
  it("keeps role tools out of the member profile", () => {
    harness.role = "member";
    harness.platformRole = null;
    harness.platformRoleExpiresAt = null;
    render(<MemoryRouter><YouPage /></MemoryRouter>);

    expect(screen.getByRole("heading", { name: "Profile and settings" })).toBeVisible();
    expect(screen.queryByRole("navigation", { name: "Role tools" })).not.toBeInTheDocument();
    const sections = screen.getByRole("navigation", { name: "Profile and settings sections" });
    expect(screen.getByRole("link", { name: "Profile" })).toHaveAttribute("href", "#profile-settings");
    expect(screen.getByRole("link", { name: "Security" })).toHaveAttribute("href", "#password-settings");
    expect(screen.getByRole("link", { name: "Notifications" })).toHaveAttribute("href", "#notification-settings");
    expect(sections).toContainElement(screen.getByRole("link", { name: "Profile" }));
  });

  it("provides direct role-gated people, safety and operations entries", () => {
    harness.role = "owner";
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
  });
});
