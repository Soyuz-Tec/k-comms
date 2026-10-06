import { getChatPageHarness, resetChatPageHarness } from "./ChatPage.testSupport";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it } from "vitest";
import { storeDraft } from "../../lib/drafts";
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();
describe("Inbox triage", () => {
  beforeEach(() => {
    resetChatPageHarness();
    harness.conversations.push({ ...harness.conversations[0]!, id: "conversation-2", title: "Planning", unread_count: 0, favorite: true,
      inbox: { message: { id: "message-2", sequence: 2, sender_user_id: "user-2", sender_display_name: "Grace",
        status: "active", excerpt: "Review the launch plan", inserted_at: "2026-10-06T10:00:00Z" }, draft: null } });
  });

  it("shows sender previews, places favorites first, and filters them with an accessible action", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app/?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    const list = screen.getByRole("navigation", { name: "Conversation list" });
    expect(within(list).getByText("Grace: Review the launch plan")).toBeVisible();
    expect(within(list).getAllByRole("button")[0]).toHaveTextContent("Planning");
    await user.click(screen.getByRole("button", { name: "Favorites" }));
    expect(within(list).queryByText("General")).not.toBeInTheDocument();
    await user.click(within(list).getByRole("button", { name: "Remove Planning from favorites" }));
    expect(harness.updateConversationFavorite).toHaveBeenCalledWith("conversation-2", false);
  });

  it("shows unsent local drafts immediately and never replaces a local clear with an old synchronized draft", () => {
    harness.conversations[1]!.inbox!.draft = { excerpt: "Remote older draft", expires_at: "2099-01-01T00:00:00Z" };
    render(<MemoryRouter initialEntries={["/app/?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    const list = screen.getByRole("navigation", { name: "Conversation list" });
    expect(within(list).getByText("Draft: Remote older draft")).toBeVisible();
    act(() => storeDraft("tenant-1", "user-1", "conversation-2", "Unsent local reply"));
    expect(within(list).getByText("Draft: Unsent local reply")).toBeVisible();
    act(() => storeDraft("tenant-1", "user-1", "conversation-2", ""));
    expect(within(list).queryByText(/Draft:/)).not.toBeInTheDocument();
    expect(within(list).getByText("Grace: Review the launch plan")).toBeVisible();
  });

  it("does not disclose removed message text or another identity's draft", () => {
    harness.conversations[1]!.inbox!.message!.status = "moderated";
    storeDraft("tenant-1", "another-user", "conversation-2", "PRIVATE DRAFT");
    render(<MemoryRouter initialEntries={["/app/?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    const list = screen.getByRole("navigation", { name: "Conversation list" });
    expect(within(list).getByText("Message removed")).toBeVisible();
    expect(within(list).queryByText(/Review the launch plan|PRIVATE DRAFT/)).not.toBeInTheDocument();
  });

  it("keeps a failed favorite operation retryable and reports it without switching conversations", async () => {
    harness.updateConversationFavorite.mockRejectedValueOnce(new Error("offline"));
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app/?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await user.click(screen.getByRole("button", { name: "Remove Planning from favorites" }));
    expect(await screen.findByText("Could not update favorites. Try again.")).toBeVisible();
    await waitFor(() => expect(screen.getByRole("button", { name: "Remove Planning from favorites" })).toBeEnabled());
    expect(screen.getByRole("button", { name: /General.*unread/ })).toHaveAttribute("aria-current", "page");
  });
});
