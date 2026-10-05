import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "../../types";
import { SavedItemsPage } from "./SavedItemsPage";

const api = vi.hoisted(() => ({ savedItems: vi.fn(), unsaveMessage: vi.fn(), saveMessage: vi.fn() }));
const identity = vi.hoisted(() => ({ user: { id: "user", role: "owner", version: 1 } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api, session: { user: identity.user, tenant: { id: "tenant" }, device: { id: "device" } } }) }));
vi.mock("../../app/workspace-data", () => ({ useOptionalWorkspaceData: () => ({ users: [{ id: "user", display_name: "Ada Lovelace" }], conversations: [{ id: "conversation", kind: "channel", title: "Product planning" }] }) }));
function message(id: string, body: string): Message { return { id, tenant_id: "tenant", conversation_id: "conversation", sender_user_id: "user", sender_device_id: "device", client_message_id: id, conversation_sequence: 1, body, metadata: {}, status: "active", inserted_at: "2026-10-04T12:00:00Z", attachments: [], reactions: [] }; }
function renderPage() { return render(<MemoryRouter><SavedItemsPage /></MemoryRouter>); }

describe("saved item pagination and authorization recovery", () => {
  beforeEach(() => { vi.resetAllMocks(); identity.user.role = "owner"; });
  it("appends the server cursor page and removes through the real saved command", async () => {
    const first = message("first", "First source"); const second = message("second", "Second source");
    api.savedItems.mockResolvedValueOnce({ data: [first], page: { truncated: true, has_more: true, next_cursor: "next-page" } }).mockResolvedValueOnce({ data: [second], page: { truncated: false, has_more: false, next_cursor: null } });
    api.unsaveMessage.mockResolvedValue(undefined);
    renderPage(); const user = userEvent.setup();
    expect(await screen.findByRole("link", { name: /First source/ })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "More saved messages" }));
    expect(await screen.findByRole("link", { name: /Second source/ })).toBeVisible();
    expect(screen.getByRole("link", { name: /First source/ })).toBeVisible();
    expect(api.savedItems).toHaveBeenLastCalledWith("next-page");
    const remove = screen.getAllByRole("button", { name: "Remove saved message 1" })[0];
    if (!remove) throw new Error("Expected a saved item remove action");
    await user.click(remove);
    await waitFor(() => expect(screen.queryByRole("link", { name: /First source/ })).not.toBeInTheDocument());
    expect(api.unsaveMessage).toHaveBeenCalledWith("first");
  });
  it("shows message provenance and restores a removed message through the real save command", async () => {
    api.savedItems.mockResolvedValue({ data: [message("first", "Review the launch plan")], page: { next_cursor: null } });
    api.unsaveMessage.mockResolvedValue(undefined); api.saveMessage.mockResolvedValue(undefined);
    renderPage(); const user = userEvent.setup();
    const source = await screen.findByRole("link", { name: /Review the launch plan/ });
    expect(source).toHaveAttribute("href", "/app/?conversation=conversation&message=first");
    expect(screen.getByText("Ada Lovelace")).toBeVisible();
    expect(screen.getByText("in Product planning")).toBeVisible();
    expect(screen.getByText(/Message sent/)).toHaveAttribute("datetime", "2026-10-04T12:00:00Z");
    await user.click(screen.getByRole("button", { name: "Remove saved message 1" }));
    expect(await screen.findByRole("button", { name: "Undo" })).toBeEnabled();
    expect(screen.queryByRole("link", { name: /Review the launch plan/ })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Undo" }));
    expect(await screen.findByRole("link", { name: /Review the launch plan/ })).toBeVisible();
    expect(api.saveMessage).toHaveBeenCalledWith("first");
    expect(screen.queryByRole("button", { name: "Undo" })).not.toBeInTheDocument();
  });
  it("clears the removed message and Undo when restoration loses conversation access", async () => {
    api.savedItems.mockResolvedValue({ data: [message("first", "Private source")], page: { next_cursor: null } });
    api.unsaveMessage.mockResolvedValue(undefined); api.saveMessage.mockRejectedValue({ status: 403 });
    renderPage(); const user = userEvent.setup();
    await screen.findByRole("link", { name: /Private source/ });
    await user.click(screen.getByRole("button", { name: "Remove saved message 1" }));
    await user.click(await screen.findByRole("button", { name: "Undo" }));
    expect(await screen.findByRole("alert")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Undo" })).not.toBeInTheDocument();
    expect(screen.queryByText("Private source")).not.toBeInTheDocument();
  });
  it("does not restore stale content after the same API client changes user authority", async () => {
    let complete!: () => void;
    const pending = new Promise<void>(resolve => { complete = resolve; });
    api.savedItems.mockResolvedValueOnce({ data: [message("first", "Private source")], page: { next_cursor: null } }).mockResolvedValue({ data: [], page: { next_cursor: null } });
    api.unsaveMessage.mockResolvedValue(undefined); api.saveMessage.mockReturnValue(pending);
    const { rerender } = renderPage(); const user = userEvent.setup();
    await screen.findByRole("link", { name: /Private source/ });
    await user.click(screen.getByRole("button", { name: "Remove saved message 1" }));
    await user.click(await screen.findByRole("button", { name: "Undo" }));
    identity.user.role = "member";
    rerender(<MemoryRouter><SavedItemsPage /></MemoryRouter>);
    await act(async () => complete());
    expect(screen.queryByRole("link", { name: /Private source/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Undo" })).not.toBeInTheDocument();
    expect(api.savedItems).toHaveBeenCalledTimes(2);
  });
  it("clears previously loaded content after authorization is denied", async () => {
    api.savedItems.mockResolvedValueOnce({ data: [message("first", "Private source")], page: { truncated: true, next_cursor: "next-page" } }).mockRejectedValueOnce({ status: 403, message: "Access changed" });
    renderPage(); expect(await screen.findByRole("link", { name: /Private source/ })).toBeVisible();
    await userEvent.setup().click(screen.getByRole("button", { name: "More saved messages" }));
    await waitFor(() => expect(screen.queryByRole("link", { name: /Private source/ })).not.toBeInTheDocument());
    expect(screen.getByRole("alert")).toBeVisible();
  });
});
