import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
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
    window.localStorage.clear();
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
      discoverPublicChannels: vi.fn().mockResolvedValue({ data: [], page: { limit: 25, has_more: false, next_cursor: null } }),
      createModerationCase: vi.fn().mockResolvedValue({ id: "case-1" }),
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

  it("keeps the reader's history position and offers an announced jump for new messages", async () => {
    const user = userEvent.setup();
    const scrollIntoView = vi.spyOn(Element.prototype, "scrollIntoView");
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    const messageScroll = document.querySelector<HTMLElement>(".message-scroll");
    expect(messageScroll).not.toBeNull();
    Object.defineProperties(messageScroll!, {
      scrollHeight: { configurable: true, value: 1_000 },
      clientHeight: { configurable: true, value: 300 },
      scrollTop: { configurable: true, value: 100, writable: true }
    });
    fireEvent.scroll(messageScroll!);
    expect(await screen.findByRole("button", { name: "Jump to latest" })).toBeVisible();
    scrollIntoView.mockClear();

    act(() => harness.callbacks?.onMessages([{ ...message(2), sender_user_id: "user-2" }]));

    const jump = await screen.findByRole("button", { name: "1 new message · Jump to latest" });
    expect(screen.getByRole("status", { name: "" })).toHaveTextContent("1 new message");
    expect(scrollIntoView).not.toHaveBeenCalled();
    await user.click(jump);
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: /Jump to latest/ })).not.toBeInTheDocument();
    scrollIntoView.mockRestore();
  });

  it("provides usable first actions when the workspace has no conversations", async () => {
    const user = userEvent.setup();
    harness.conversations = [];
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    await user.click(screen.getByRole("button", { name: "Start a conversation" }));
    expect(screen.getByRole("heading", { name: "New conversation" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    const browseActions = screen.getAllByRole("button", { name: "Browse channels" });
    await user.click(browseActions.at(-1)!);
    expect(await screen.findByRole("dialog", { name: "Browse channels" })).toBeVisible();
  });

  it("shows a tenant-scoped first-run checklist that can be dismissed without telemetry", async () => {
    const user = userEvent.setup();
    harness.conversations = [];
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    expect(screen.getByRole("heading", { name: "Get started" })).toBeVisible();
    expect(screen.getByText("Choose or start a conversation")).toBeVisible();
    expect(screen.getByRole("link", { name: "Choose notification preferences" })).toHaveAttribute("href", "/app/settings");

    await user.click(screen.getByRole("button", { name: "Dismiss getting-started checklist" }));
    expect(screen.queryByRole("heading", { name: "Get started" })).not.toBeInTheDocument();
    expect(window.localStorage.getItem("k-comms:onboarding:tenant-1:user-1")).toBe("dismissed");
  });

  it("filters the conversation list by title, kind, and unread state without server requests", async () => {
    const user = userEvent.setup();
    harness.conversations = [
      { ...harness.conversations[0]!, id: "conversation-1", title: "General", kind: "channel", unread_count: 1 },
      { ...harness.conversations[0]!, id: "conversation-2", title: "Project Alpha", kind: "group", unread_count: 0 },
      { ...harness.conversations[0]!, id: "conversation-3", title: "Grace", kind: "direct", unread_count: 0 }
    ];
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    const list = screen.getByRole("navigation", { name: "Conversation list" });

    await user.type(screen.getByLabelText("Filter conversations by title"), "project");
    expect(within(list).getByRole("button", { name: /Project Alpha/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /General/ })).not.toBeInTheDocument();

    await user.clear(screen.getByLabelText("Filter conversations by title"));
    await user.selectOptions(screen.getByLabelText("Conversation type"), "direct");
    expect(within(list).getByRole("button", { name: /Grace/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /Project Alpha/ })).not.toBeInTheDocument();

    await user.selectOptions(screen.getByLabelText("Conversation type"), "all");
    await user.click(screen.getByRole("checkbox", { name: "Unread only" }));
    expect(within(list).getByRole("button", { name: /General/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /Grace/ })).not.toBeInTheDocument();
  });

  it("submits a message report with the same moderated payload through an accessible dialog", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    await user.click(await screen.findByRole("button", { name: "Report" }));
    expect(screen.getByRole("alertdialog", { name: "Report this message?" })).toBeVisible();
    await user.type(screen.getByLabelText("Reason for reporting this message"), "Contains a sensitive customer identifier");
    await user.click(screen.getByRole("button", { name: "Submit report" }));

    await waitFor(() => expect(harness.api.createModerationCase).toHaveBeenCalledWith({
      message_id: "message-1",
      conversation_id: "conversation-1",
      category: "message_content",
      summary: "Contains a sensitive customer identifier",
      details: "Contains a sensitive customer identifier",
      priority: "normal"
    }));
    expect(await screen.findByText("Report submitted to workspace moderators.")).toBeVisible();
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });
});
