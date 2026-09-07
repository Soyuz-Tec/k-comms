import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { Conversation, Session } from "../types";
import { WorkspaceSwitcher, workspaceDestinations } from "./WorkspaceSwitcher";

const session: Session = {
  access_token: "synthetic", refresh_token: "synthetic", token_type: "Bearer", expires_in: 900,
  tenant: { id: "tenant", name: "Example", slug: "example", status: "active" },
  user: { id: "user", tenant_id: "tenant", display_name: "Taylor", email: "taylor@example.test", role: "member", status: "active" },
  device: { id: "device", user_id: "user", name: "Browser", platform: "web" }
};
const conversation: Conversation = {
  id: "room/one", tenant_id: "tenant", title: "Project Aurora", kind: "channel", visibility: "private",
  counterpart_user_id: null, counterpart_display_name: null, latest_sequence: 1,
  inserted_at: "2026-09-07T00:00:00Z", updated_at: "2026-09-07T00:00:00Z"
};

describe("workspace switcher", () => {
  it("uses only current authorized conversations and correctly encodes navigation", () => {
    const result = workspaceDestinations(session, [conversation, { ...conversation, id: "archived", archived_at: "2026-09-01T00:00:00Z" }]);
    expect(result.find(({ id }) => id === conversation.id)).toMatchObject({ label: "Project Aurora", path: "/app/?conversation=room%2Fone" });
    expect(result.some(({ id }) => id === "archived" || id === "admin" || id === "ops")).toBe(false);
  });

  it("limits role tools to current authority, including the operations deadline", () => {
    const owner: Session = { ...session, user: { ...session.user, role: "owner", platform_role: "platform_operator", platform_role_expires_at: new Date(Date.now() + 60_000).toISOString() } };
    expect(workspaceDestinations(owner, []).map(({ id }) => id)).toEqual(expect.arrayContaining(["admin", "ops"]));
    owner.user.platform_role_expires_at = new Date(Date.now() - 1).toISOString();
    expect(workspaceDestinations(owner, []).some(({ id }) => id === "ops")).toBe(false);
  });

  it("disambiguates identical people and room names so every result remains searchable", async () => {
    const user = userEvent.setup();
    const conversations = Array.from({ length: 14 }, (_, index) => ({ ...conversation, id: `dm-${index}`, kind: "direct" as const,
      counterpart_user_id: `person-${index}`, counterpart_display_name: "Sam Lee" }));
    const destinations = workspaceDestinations(session, conversations);
    const labels = destinations.filter(({ detail }) => detail === "Direct message").map(({ label }) => label);
    expect(new Set(labels).size).toBe(14);
    const last = labels.at(-1)!;
    render(<MemoryRouter><WorkspaceSwitcher session={session} conversations={conversations} onClose={() => {}} /></MemoryRouter>);
    await user.type(screen.getByRole("combobox"), last);
    expect(screen.getByRole("option")).toHaveTextContent(last);
    const rooms = workspaceDestinations(session, [conversation, { ...conversation, id: "other-room" }]).filter(({ detail }) => detail === "Channel");
    expect(rooms).toHaveLength(2);
    expect(rooms[0]!.label).not.toBe(rooms[1]!.label);
  });

  it("filters names, exposes empty state and supports keyboard selection", async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    render(<MemoryRouter><WorkspaceSwitcher session={session} conversations={[conversation]} onClose={onClose} /></MemoryRouter>);
    const input = screen.getByRole("combobox");
    await user.type(input, "nothing-matches");
    expect(screen.getByRole("status")).toHaveTextContent("No matching destination");
    expect(screen.queryByRole("option")).not.toBeInTheDocument();
    await user.clear(input);
    await user.type(input, "aurora");
    expect(screen.getByRole("option")).toHaveTextContent("Project Aurora");
    expect(screen.getByRole("option")).toHaveAttribute("aria-selected", "true");
    await user.keyboard("{ArrowDown}{Enter}");
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("bounds the initial list but keeps every authorized conversation searchable", async () => {
    const user = userEvent.setup();
    const conversations = Array.from({ length: 40 }, (_, index) => ({ ...conversation, id: String(index), title: `Room ${index}` }));
    render(<MemoryRouter><WorkspaceSwitcher session={session} conversations={conversations} onClose={() => {}} /></MemoryRouter>);
    expect(screen.getAllByRole("option")).toHaveLength(12);
    expect(screen.getByRole("status")).toHaveTextContent("keep typing");
    await user.type(screen.getByRole("combobox"), "Room 39");
    expect(screen.getAllByRole("option")).toHaveLength(1);
    expect(screen.getByRole("option")).toHaveTextContent("Room 39");
  });

  it("does not navigate while Enter confirms an IME composition", () => {
    const onClose = vi.fn();
    render(<MemoryRouter><WorkspaceSwitcher session={session} conversations={[conversation]} onClose={onClose} /></MemoryRouter>);
    const input = screen.getByRole("combobox");
    fireEvent.keyDown(input, { key: "Enter", isComposing: true });
    fireEvent.keyDown(input, { key: "Enter", keyCode: 229 });
    expect(onClose).not.toHaveBeenCalled();
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onClose).toHaveBeenCalledOnce();
  });
});
