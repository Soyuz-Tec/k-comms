import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Conversation, ConversationMembership, User } from "../../types";
import { ConversationDetails } from "./ConversationDetails";

const conversation: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "General",
  visibility: "tenant",
  latest_sequence: 4,
  version: 8,
  inserted_at: "2026-07-12T10:00:00Z",
  updated_at: "2026-07-12T10:00:00Z"
};

const currentUser: User = { id: "user-1", tenant_id: "tenant-1", display_name: "Ada", email: "ada@example.test", role: "member", status: "active" };
const teammate: User = { id: "user-2", tenant_id: "tenant-1", display_name: "Grace", email: "grace@example.test", role: "member", status: "active" };

function membership(id: string, user: User, role: ConversationMembership["role"], version: number): ConversationMembership {
  return { id, user, role, version, joined_at: "2026-07-12T10:00:00Z", last_read_sequence: 0 };
}

function apiFor(members: ConversationMembership[]) {
  return {
    conversationMembers: vi.fn().mockResolvedValue(members),
    addConversationMember: vi.fn().mockResolvedValue(undefined),
    removeConversationMember: vi.fn().mockResolvedValue(undefined),
    updateConversationMember: vi.fn().mockResolvedValue(undefined),
    updateConversation: vi.fn().mockResolvedValue(conversation),
    archiveConversation: vi.fn().mockResolvedValue({ ...conversation, archived_at: "2026-07-14T10:00:00Z" }),
    leavePublicChannel: vi.fn().mockResolvedValue({ data: { conversation, membership: members[0] }, replayed: false })
  };
}

describe("ConversationDetails confirmations", () => {
  it("confirms member removal with the exact concurrency version and restores the action on cancel", async () => {
    const user = userEvent.setup();
    const members = [membership("member-current", currentUser, "owner", 3), membership("member-grace", teammate, "member", 7)];
    const api = apiFor(members);
    render(<ConversationDetails api={api as unknown as ApiClient} conversation={conversation} currentUserId={currentUser.id} users={[currentUser, teammate]} onClose={vi.fn()} onLeft={vi.fn()} onUpdated={vi.fn()} />);

    const remove = await screen.findByRole("button", { name: "Remove" });
    await user.click(remove);
    expect(screen.getByRole("alertdialog", { name: "Remove Grace?" })).toBeVisible();
    expect(screen.queryByRole("dialog", { name: "General" })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    const restoredRemove = await screen.findByRole("button", { name: "Remove" });
    await waitFor(() => expect(restoredRemove).toHaveFocus());
    expect(api.removeConversationMember).not.toHaveBeenCalled();

    await user.click(restoredRemove);
    await user.click(screen.getByRole("button", { name: "Remove member" }));
    await waitFor(() => expect(api.removeConversationMember).toHaveBeenCalledWith("conversation-1", "user-2", 7));
  });

  it("confirms archive and passes the conversation version unchanged", async () => {
    const user = userEvent.setup();
    const members = [membership("member-current", currentUser, "owner", 3)];
    const api = apiFor(members);
    const onClose = vi.fn();
    const onUpdated = vi.fn();
    render(<ConversationDetails api={api as unknown as ApiClient} conversation={conversation} currentUserId={currentUser.id} users={[currentUser]} onClose={onClose} onLeft={vi.fn()} onUpdated={onUpdated} />);

    await user.click(await screen.findByRole("button", { name: "Archive" }));
    expect(screen.getByRole("alertdialog", { name: "Archive General?" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Archive conversation" }));

    await waitFor(() => expect(api.archiveConversation).toHaveBeenCalledWith("conversation-1", 8));
    expect(onUpdated).toHaveBeenCalledWith(expect.objectContaining({ archived_at: "2026-07-14T10:00:00Z" }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("confirms leaving a channel and passes the current membership version unchanged", async () => {
    const user = userEvent.setup();
    const members = [membership("member-current", currentUser, "member", 11)];
    const api = apiFor(members);
    const onLeft = vi.fn();
    render(<ConversationDetails api={api as unknown as ApiClient} conversation={conversation} currentUserId={currentUser.id} users={[currentUser]} onClose={vi.fn()} onLeft={onLeft} onUpdated={vi.fn()} />);

    await user.click(await screen.findByRole("button", { name: "Leave channel" }));
    expect(screen.getByRole("alertdialog", { name: "Leave General?" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Leave channel" }));

    await waitFor(() => expect(api.leavePublicChannel).toHaveBeenCalledWith("conversation-1", 11));
    expect(onLeft).toHaveBeenCalledTimes(1);
  });
});
