import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation, Message } from "../../types";
import type { RealtimeCallbacks } from "../../realtime";
import { ChatPage } from "./ChatPage";

const harness = vi.hoisted(() => ({
  callbacks: null as RealtimeCallbacks | null,
  markRead: vi.fn<(sequence: number) => Promise<unknown>>(),
  sendMessage: vi.fn<(input: unknown) => Promise<Message>>(),
  setError: vi.fn(),
  setConversations: vi.fn(),
  createConversation: vi.fn(),
  refreshConversations: vi.fn().mockResolvedValue(undefined),
  conversations: [{ id: "conversation-1", tenant_id: "tenant-1", kind: "channel", title: "General", visibility: "tenant", latest_sequence: 1, unread_count: 1, last_read_sequence: 0, version: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" }] as Conversation[],
  api: {} as Record<string, ReturnType<typeof vi.fn>>
}));

vi.mock("../../realtime", () => ({
  socketEndpoint: () => "/socket",
  RealtimeConversation: class {
    constructor(_endpoint: string, _ticket: string, _conversationId: string, _after: () => number, callbacks: RealtimeCallbacks) {
      harness.callbacks = callbacks;
    }
    connect() { harness.callbacks?.onStatus("live"); }
    disconnect() { /* test double */ }
    markRead(sequence: number) { return harness.markRead(sequence); }
    sendMessage(input: unknown) { return harness.sendMessage(input); }
    setTyping() { /* test double */ }
  }
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: harness.api,
    session: {
      access_token: "access",
      refresh_token: "refresh",
      token_type: "Bearer",
      expires_in: 900,
      tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" },
      user: { id: "user-1", tenant_id: "tenant-1", display_name: "Ada", email: "ada@example.test", role: "member", status: "active" },
      device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
    }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    conversations: harness.conversations,
    users: [{ id: "user-1", tenant_id: "tenant-1", display_name: "Ada", email: "ada@example.test", role: "member", status: "active" }],
    capabilities: { allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 },
    loading: false,
    setError: harness.setError,
    setConversations: harness.setConversations,
    createConversation: harness.createConversation,
    refreshConversations: harness.refreshConversations
  })
}));

function message(sequence: number): Message {
  return {
    id: `message-${sequence}`,
    tenant_id: "tenant-1",
    conversation_id: "conversation-1",
    sender_user_id: "user-1",
    sender_device_id: "device-1",
    client_message_id: `client-${sequence}`,
    conversation_sequence: sequence,
    body: `Message ${sequence}`,
    metadata: {},
    status: "active",
    inserted_at: "2026-07-12T10:00:00Z",
    attachments: [],
    reactions: []
  };
}

describe("ChatPage durable sequence recovery", () => {
  beforeEach(() => {
    harness.callbacks = null;
    harness.conversations = [{ id: "conversation-1", tenant_id: "tenant-1", kind: "channel", title: "General", visibility: "tenant", latest_sequence: 1, unread_count: 1, last_read_sequence: 0, version: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" }];
    harness.markRead.mockReset().mockResolvedValue({});
    harness.sendMessage.mockReset().mockResolvedValue(message(2));
    Object.assign(harness.api, {
      socketTicket: vi.fn().mockResolvedValue({ ticket: "one-time-ticket", expires_in: 60 }),
      messages: vi.fn().mockResolvedValue({ data: [message(1)], page: { has_more: false, next_after_sequence: null, reset_required: false } }),
      conversationMembers: vi.fn().mockResolvedValue([
        { id: "membership-current", role: "member", joined_at: "2026-07-12T10:00:00Z", last_read_sequence: 0, user: { id: "user-1", tenant_id: "tenant-1", display_name: "Ada", account_type: "human", role: "member", status: "active" } },
        { id: "membership-human", role: "member", joined_at: "2026-07-12T10:00:00Z", last_read_sequence: 0, user: { id: "user-2", tenant_id: "tenant-1", display_name: "Grace", account_type: "human", role: "member", status: "active" } },
        { id: "membership-service", role: "member", joined_at: "2026-07-12T10:00:00Z", last_read_sequence: 0, user: { id: "service-1", tenant_id: "tenant-1", display_name: "Build bot", account_type: "service", role: "member", status: "active" } }
      ]),
      messageThread: vi.fn().mockResolvedValue({ data: { root: message(1), replies: [], reply_count: 0 }, page: { has_more: false, next_before_sequence: null } })
    });
  });

  it("connects realtime after a saved conversation becomes available", async () => {
    harness.conversations = [];
    const view = render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(harness.callbacks).toBeNull();
    harness.conversations = [{ id: "conversation-1", tenant_id: "tenant-1", kind: "channel", title: "General", visibility: "tenant", latest_sequence: 1, unread_count: 1, last_read_sequence: 0, version: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" }];
    view.rerender(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    expect(await screen.findByText("Live")).toBeInTheDocument();
  });

  it("fetches a missing durable sequence and never marks past the contiguous cursor", async () => {
    let resolveCatchUp: ((value: unknown) => void) | undefined;
    const catchUp = new Promise((resolve) => { resolveCatchUp = resolve; });
    harness.api.messages!
      .mockResolvedValueOnce({ data: [message(1)], page: { has_more: false, next_after_sequence: null, reset_required: false } })
      .mockReturnValueOnce(catchUp);

    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    act(() => harness.callbacks?.onMessages([message(3)]));
    await waitFor(() => expect(harness.api.messages).toHaveBeenCalledWith("conversation-1", 1, 200));
    await new Promise((resolve) => window.setTimeout(resolve, 550));
    expect(harness.markRead).not.toHaveBeenCalledWith(3);

    resolveCatchUp?.({ data: [message(2), message(3)], page: { has_more: false, next_after_sequence: null, reset_required: false } });
    await waitFor(() => expect(harness.markRead).toHaveBeenCalledWith(3), { timeout: 2_000 });
  });

  it("merges a realtime reply into an open canonical thread", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    await user.click(await screen.findByRole("button", { name: "Start thread" }));
    expect(await screen.findByRole("dialog", { name: "Thread" })).toBeInTheDocument();

    const reply = {
      ...message(2),
      body: "Realtime thread reply",
      reply_to_message_id: "message-1",
      thread_root_message_id: "message-1",
      thread_reply_count: 1
    };
    act(() => harness.callbacks?.onMessages([reply]));

    expect(await screen.findAllByText("Realtime thread reply")).toHaveLength(2);
  });

  it("opens a safely parsed notification message deep link as a thread", async () => {
    const linkedMessageId = "33333333-3333-4333-8333-333333333333";
    render(
      <MemoryRouter initialEntries={[`/app?conversation=conversation-1&message=${linkedMessageId}`]}>
        <ChatPage />
      </MemoryRouter>
    );

    await waitFor(() =>
      expect(harness.api.messageThread).toHaveBeenCalledWith("conversation-1", linkedMessageId)
    );
  });

  it("keeps explicit mention IDs across a failed-send retry and hides service identities", async () => {
    const user = userEvent.setup();
    harness.sendMessage
      .mockRejectedValueOnce(new Error("temporary disconnect"))
      .mockResolvedValueOnce({ ...message(2), mentioned_user_ids: ["user-2"] });

    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    await user.click(await screen.findByRole("button", { name: "Mention" }));
    expect(screen.queryByText("Build bot")).not.toBeInTheDocument();
    await user.click(screen.getByRole("checkbox", { name: "Grace" }));
    await user.type(screen.getByLabelText("Message"), "Mention retry");
    await user.click(screen.getByRole("button", { name: /Send/ }));

    await user.click(await screen.findByRole("button", { name: "Retry" }));
    await waitFor(() => expect(harness.sendMessage).toHaveBeenCalledTimes(2));
    expect(harness.sendMessage.mock.calls[0]?.[0]).toMatchObject({ mentioned_user_ids: ["user-2"] });
    expect(harness.sendMessage.mock.calls[1]?.[0]).toMatchObject({ mentioned_user_ids: ["user-2"] });
  });
});
