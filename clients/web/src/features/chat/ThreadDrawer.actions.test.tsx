import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ThreadDrawer } from "./ThreadDrawer";
import { apiDouble, currentUser, deferred, membership, message, mentionedUser, renderDrawer } from "./ThreadDrawer.testSupport";

describe("ThreadDrawer message controls", () => {
  beforeEach(() => window.localStorage.clear());

  it("offers author actions only on owned active messages and reports another author's reply", async () => {
    const user = userEvent.setup();
    const reply = { ...message("other-reply", 2, "Grace reply"), sender_user_id: mentionedUser.id, thread_root_message_id: "root-1" };
    const removed = { ...message("removed-reply", 3, "Removed body"), status: "deleted" as const, thread_root_message_id: "root-1" };
    const onReport = vi.fn();
    renderDrawer({ api: apiDouble({ messageThread: vi.fn().mockResolvedValue({ data: { root: message("root-1", 1, "Root message"), replies: [reply, removed] }, page: { has_more: false } }) }), onReport });
    const root = (await screen.findByText("Root message")).closest("article")!;
    expect(within(root).getByRole("button", { name: "Edit" })).toBeVisible();
    expect(within(root).getByRole("button", { name: "Delete" })).toBeVisible();
    const other = screen.getByText("Grace reply").closest("article")!;
    expect(within(other).queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(within(other).queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
    await user.click(within(other).getByRole("button", { name: "Report" }));
    expect(onReport).toHaveBeenCalledWith(reply);
    const tombstone = screen.getByText("Message removed").closest("article")!;
    expect(within(tombstone).queryByRole("button", { name: /Edit|Delete|Report/ })).not.toBeInTheDocument();
    expect(document.getElementById("thread-message-root-1")).toBeInTheDocument();
    expect(document.getElementById("message-root-1")).not.toBeInTheDocument();
  });

  it("keeps an edit draft on policy denial, then reconciles a successful retry", async () => {
    const user = userEvent.setup();
    const updated = { ...message("root-1", 1, "Revised root"), edited_at: "2026-10-04T12:05:00Z" };
    const editMessage = vi.fn().mockRejectedValueOnce(new Error("Message edit window expired")).mockResolvedValueOnce(updated);
    const onMessageUpdated = vi.fn();
    renderDrawer({ api: apiDouble({ editMessage }), onMessageUpdated });
    await user.click(within((await screen.findByText("Root message")).closest("article")!).getByRole("button", { name: "Edit" }));
    await user.clear(screen.getByRole("textbox", { name: "Edit message" }));
    await user.type(screen.getByRole("textbox", { name: "Edit message" }), "Revised root");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Message edit window expired");
    expect(screen.getByRole("textbox", { name: "Edit message" })).toHaveValue("Revised root");
    expect(onMessageUpdated).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByText("Revised root")).toBeVisible();
    expect(editMessage).toHaveBeenLastCalledWith("root-1", "Revised root");
    expect(onMessageUpdated).toHaveBeenCalledWith(updated);
  });

  it("requires confirmation before deleting a thread message and reconciles its tombstone", async () => {
    const user = userEvent.setup();
    const tombstone = { ...message("root-1", 1, ""), status: "deleted" as const };
    const deleteMessage = vi.fn().mockResolvedValue(tombstone);
    const onMessageUpdated = vi.fn();
    renderDrawer({ api: apiDouble({ deleteMessage }), onMessageUpdated });
    await user.click(within((await screen.findByText("Root message")).closest("article")!).getByRole("button", { name: "Delete" }));
    expect(deleteMessage).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Delete message" }));
    expect(await screen.findByText("Message removed")).toBeVisible();
    expect(deleteMessage).toHaveBeenCalledWith("root-1");
    expect(onMessageUpdated).toHaveBeenCalledWith(tombstone);
  });

  it("adds and removes reactions using the same conversation APIs and updates the live feed", async () => {
    const user = userEvent.setup();
    const addReaction = vi.fn().mockResolvedValue(undefined);
    const removeReaction = vi.fn().mockResolvedValue(undefined);
    const onMessageUpdated = vi.fn();
    renderDrawer({ api: apiDouble({ addReaction, removeReaction }), onMessageUpdated });
    await screen.findByText("Root message");
    await user.click(screen.getByRole("button", { name: "React with 👍" }));
    expect(await screen.findByRole("button", { name: "Remove 👍 reaction; 1 total" })).toHaveAttribute("aria-pressed", "true");
    expect(addReaction).toHaveBeenCalledWith("conversation-1", "root-1", "👍");
    await user.click(screen.getByRole("button", { name: "Remove 👍 reaction; 1 total" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Remove 👍 reaction; 1 total" })).not.toBeInTheDocument());
    expect(removeReaction).toHaveBeenCalledWith("conversation-1", "root-1", "👍");
    expect(onMessageUpdated).toHaveBeenLastCalledWith(expect.objectContaining({ id: "root-1", reactions: [] }));
  });

  it.each([
    { surface: "root", status: "deleted" as const },
    { surface: "root", status: "moderated" as const },
    { surface: "reply", status: "deleted" as const },
    { surface: "reply", status: "moderated" as const }
  ])("keeps a live $status $surface removed when an earlier edit response arrives", async ({ surface, status }) => {
    const user = userEvent.setup();
    const pending = deferred<ReturnType<typeof message>>();
    const root = message("root-1", 1, "Root message");
    const reply = { ...message("reply-1", 2, "Original reply"), thread_root_message_id: root.id };
    const edited = surface === "root" ? root : reply;
    const liveMessages = [root, reply];
    const editMessage = vi.fn().mockReturnValue(pending.promise);
    const api = apiDouble({ editMessage, messageThread: vi.fn().mockResolvedValue({ data: { root, replies: [reply] }, page: { has_more: false } }) });
    const onMessageUpdated = vi.fn();
    const props = { api, tenantId: "tenant-1", conversationId: "conversation-1", targetMessageId: root.id, currentUserId: currentUser.id, members: [membership(currentUser)], users: [currentUser], liveMessages, onClose: vi.fn(), onSend: vi.fn(), onReport: vi.fn(), onMessageUpdated };
    const view = render(<ThreadDrawer {...props} />);
    const item = (await screen.findByText(edited.body!)).closest("article")!;
    await user.click(within(item).getByRole("button", { name: "Edit" }));
    await user.clear(screen.getByRole("textbox", { name: "Edit message" }));
    await user.type(screen.getByRole("textbox", { name: "Edit message" }), "Earlier edit response");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(editMessage).toHaveBeenCalledWith(edited.id, "Earlier edit response");

    const tombstone = { ...edited, body: null, status, deleted_at: "2026-10-04T12:06:00Z" };
    view.rerender(<ThreadDrawer {...props} liveMessages={liveMessages.map((entry) => entry.id === edited.id ? tombstone : entry)} />);
    expect(await within(item).findByText("Message removed")).toBeVisible();
    expect(screen.queryByRole("textbox", { name: "Edit message" })).not.toBeInTheDocument();

    await act(async () => pending.resolve({ ...edited, body: "Earlier edit response", edited_at: "2026-10-04T12:05:00Z" }));

    expect(within(item).getByText("Message removed")).toBeVisible();
    expect(within(item).queryByText("Earlier edit response")).not.toBeInTheDocument();
    expect(within(item).queryByRole("button", { name: /^(Edit|Delete|Report)$/ })).not.toBeInTheDocument();
    expect(onMessageUpdated).toHaveBeenCalledTimes(1);
    expect(onMessageUpdated).toHaveBeenCalledWith(tombstone);
  });

  it("does not apply a late edit response to a different thread or its parent feed", async () => {
    const user = userEvent.setup();
    const pending = deferred<ReturnType<typeof message>>();
    const rootA = message("root-a", 1, "Root A");
    const rootB = message("root-b", 2, "Root B");
    const api = apiDouble({ editMessage: vi.fn().mockReturnValue(pending.promise), messageThread: vi.fn((_conversation, target) => Promise.resolve({ data: { root: target === "a" ? rootA : rootB, replies: [] }, page: { has_more: false } })) });
    const onMessageUpdated = vi.fn();
    const props = { api, tenantId: "tenant-1", conversationId: "conversation-1", currentUserId: currentUser.id, members: [membership(currentUser)], users: [currentUser], liveMessages: [], onClose: vi.fn(), onSend: vi.fn(), onMessageUpdated };
    const view = render(<ThreadDrawer {...props} targetMessageId="a" />);
    await user.click(within((await screen.findByText("Root A")).closest("article")!).getByRole("button", { name: "Edit" }));
    await user.type(screen.getByRole("textbox", { name: "Edit message" }), " updated");
    await user.click(screen.getByRole("button", { name: "Save" }));
    view.rerender(<ThreadDrawer {...props} targetMessageId="b" />);
    await screen.findByText("Root B");
    pending.resolve({ ...rootA, body: "Root A updated" });
    await waitFor(() => expect(screen.getByText("Root B")).toBeVisible());
    expect(screen.queryByText("Root A updated")).not.toBeInTheDocument();
    expect(onMessageUpdated).not.toHaveBeenCalled();
  });
});
