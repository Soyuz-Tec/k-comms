import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "../../types";
import { SavedItemsPage } from "./SavedItemsPage";

const api = vi.hoisted(() => ({ savedItems: vi.fn(), unsaveMessage: vi.fn() }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api }) }));
function message(id: string, body: string): Message { return { id, tenant_id: "tenant", conversation_id: "conversation", sender_user_id: "user", sender_device_id: "device", client_message_id: id, conversation_sequence: 1, body, metadata: {}, status: "active", inserted_at: "2026-10-04T12:00:00Z", attachments: [], reactions: [] }; }
function renderPage() { return render(<MemoryRouter><SavedItemsPage /></MemoryRouter>); }

describe("saved item pagination and authorization recovery", () => {
  beforeEach(() => vi.clearAllMocks());
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
  it("clears previously loaded content after authorization is denied", async () => {
    api.savedItems.mockResolvedValueOnce({ data: [message("first", "Private source")], page: { truncated: true, next_cursor: "next-page" } }).mockRejectedValueOnce({ status: 403, message: "Access changed" });
    renderPage(); expect(await screen.findByRole("link", { name: /Private source/ })).toBeVisible();
    await userEvent.setup().click(screen.getByRole("button", { name: "More saved messages" }));
    await waitFor(() => expect(screen.queryByRole("link", { name: /Private source/ })).not.toBeInTheDocument());
    expect(screen.getByRole("alert")).toBeVisible();
  });
});
