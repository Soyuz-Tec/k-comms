import { act, cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { User } from "../types";
import { DesktopActivityRail } from "./DesktopActivityRail";

const member: User = {
  id: "member", tenant_id: "workspace", display_name: "Ada Lovelace",
  role: "member", status: "active", account_type: "human", access_scope: "workspace"
};

function Location() {
  const location = useLocation();
  return <output aria-label="Current route">{location.pathname}{location.search}{location.hash}</output>;
}

function open(user: User = member, route = "/app/") {
  return render(<MemoryRouter initialEntries={[route]}>
    <DesktopActivityRail user={user} /><Location />
  </MemoryRouter>);
}

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("DesktopActivityRail", () => {
  it("opens workspace destinations through named shortcuts and selects the new area", async () => {
    const interaction = userEvent.setup();
    open();
    const rail = screen.getByRole("navigation", { name: "Workspace shortcuts" });
    expect(within(rail).getByRole("link", { name: "Open Inbox" })).toHaveAttribute("aria-current", "page");
    expect(within(rail).getByRole("link", { name: "Open Shared documents" })).toHaveAttribute("href", "/app/documents");
    expect(within(rail).getByRole("link", { name: "Open Files" })).toHaveAttribute("href", "/app/files");
    expect(within(rail).getByRole("link", { name: "Open Directory" })).toHaveAttribute("href", "/app/directory");
    await interaction.click(within(rail).getByRole("link", { name: "Open Calls" }));
    expect(screen.getByLabelText("Current route")).toHaveTextContent("/app/calls");
    expect(within(rail).getByRole("link", { name: "Open Calls" })).toHaveAttribute("aria-current", "page");
    expect(within(rail).getByRole("link", { name: "Open Inbox" })).not.toHaveAttribute("aria-current");
    await interaction.click(within(rail).getByRole("link", { name: "Open Meetings" }));
    expect(screen.getByLabelText("Current route")).toHaveTextContent("/app/meetings");
  });

  it.each(["/app", "/app/?conversation=room"]) (
    "recognizes the Inbox at %s without selecting nested tools",
    (route) => {
      open(member, route);
      expect(screen.getByRole("link", { name: "Open Inbox" })).toHaveAttribute("aria-current", "page");
      expect(screen.getByRole("link", { name: "Open Calls" })).not.toHaveAttribute("aria-current");
    }
  );

  it("keeps the calling overview scoped and does not claim the separate Phone destination", () => {
    open(member, "/app/calls/phone?tab=history");
    expect(screen.getByRole("link", { name: "Open Calls" })).not.toHaveAttribute("aria-current");
    expect(screen.getByRole("link", { name: "Open Inbox" })).not.toHaveAttribute("aria-current");
  });

  it("retains the current conversation, document and anchor when reopening Shared documents", async () => {
    const interaction = userEvent.setup();
    const route = "/app/documents?conversation=room%2Fone&document=notes#paragraph";
    open(member, route);
    const documents = screen.getByRole("link", { name: "Open Shared documents" });
    expect(documents).toHaveAttribute("aria-current", "page");
    expect(documents).toHaveAttribute("href", route);
    await interaction.click(documents);
    expect(screen.getByLabelText("Current route")).toHaveTextContent(route);
    expect(screen.getByRole("link", { name: "Open Inbox" })).not.toHaveAttribute("aria-current");
  });

  it("names the signed-in identity and selects You independently of its settings section", () => {
    open(member, "/app/you?section=audio-video");
    expect(screen.getByRole("link", { name: "Open You (Ada Lovelace)" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "Open You (Ada Lovelace)" })).toHaveAttribute("href", "/app/you");
  });

  it.each([
    member,
    { ...member, role: "owner" as const, access_scope: "conversation_only" as const },
    { ...member, role: "owner" as const, account_type: "service" as const }
  ])("hides administration without admitted workspace authority", (user) => {
    open(user);
    expect(screen.queryByRole("link", { name: "Open Workspace administration" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Open Service operations" })).not.toBeInTheDocument();
  });

  it("offers permitted administrative areas and marks the current section", () => {
    open({ ...member, role: "security_admin" }, "/admin?section=safety");
    expect(screen.getByRole("link", { name: "Open Workspace administration" })).toHaveAttribute("aria-current", "page");
    expect(screen.queryByRole("link", { name: "Open Service operations" })).not.toBeInTheDocument();
  });

  it("shows operations under a current platform grant and withdraws the shortcut at expiry", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-05T00:00:00Z"));
    open({ ...member, platform_role: "support_operator", platform_role_expires_at: "2026-10-05T00:00:01Z" }, "/ops?queue=providers");
    expect(screen.getByRole("link", { name: "Open Service operations" })).toHaveAttribute("aria-current", "page");
    expect(screen.queryByRole("link", { name: "Open Workspace administration" })).not.toBeInTheDocument();
    act(() => vi.advanceTimersByTime(1_001));
    expect(screen.queryByRole("link", { name: "Open Service operations" })).not.toBeInTheDocument();
  });

  it.each([null, "not-a-date", "2000-01-01T00:00:00Z"])(
    "hides operations with an absent, invalid or expired deadline (%s)",
    (deadline) => {
      open({ ...member, platform_role: "platform_operator", platform_role_expires_at: deadline });
      expect(screen.queryByRole("link", { name: "Open Service operations" })).not.toBeInTheDocument();
    }
  );
});
