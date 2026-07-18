import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation, useNavigate } from "react-router-dom";
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
  audioCallsAvailable: true,
  videoCallsAvailable: true,
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
    capabilities: { allow_audio_calls: true, allow_video_calls: true, allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 },
    audioCallsAvailable: harness.audioCallsAvailable,
    videoCallsAvailable: harness.videoCallsAvailable,
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

function LocationProbe() {
  const location = useLocation();
  return <output aria-label="location-search">{location.search}</output>;
}

function HistoryBack() {
  const navigate = useNavigate();
  return <button type="button" onClick={() => navigate(-1)}>Browser back</button>;
}

function setMobileViewport(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn().mockImplementation((media: string) => ({
      matches: media === "(max-width: 760px)" ? matches : false,
      media,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(() => true)
    }))
  });
}

describe("ChatPage durable sequence recovery", () => {
  beforeEach(() => {
    setMobileViewport(false);
    window.localStorage.clear();
    harness.callbacks = null;
    harness.audioCallsAvailable = true;
    harness.videoCallsAvailable = true;
    harness.conversations = [{ id: "conversation-1", tenant_id: "tenant-1", kind: "channel", title: "General", visibility: "tenant", latest_sequence: 1, unread_count: 1, last_read_sequence: 0, version: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" }];
    harness.markRead.mockReset().mockResolvedValue({});
    harness.sendMessage.mockReset().mockResolvedValue(message(2));
    Object.assign(harness.api, {
      socketTicket: vi.fn().mockResolvedValue({ ticket: "one-time-ticket", expires_in: 60 }),
      audioCall: vi.fn().mockResolvedValue(null),
      startAudioCall: vi.fn(),
      joinAudioCall: vi.fn(),
      endAudioCall: vi.fn(),
      messages: vi.fn().mockResolvedValue({ data: [message(1)], page: { has_more: false, next_after_sequence: null, reset_required: false } }),
      conversationMembers: vi.fn().mockResolvedValue([
        { id: "membership-current", role: "member", joined_at: "2026-07-12T10:00:00Z", last_read_sequence: 0, user: { id: "user-1", tenant_id: "tenant-1", display_name: "Ada", account_type: "human", role: "member", status: "active" } },
        { id: "membership-human", role: "member", joined_at: "2026-07-12T10:00:00Z", last_read_sequence: 0, user: { id: "user-2", tenant_id: "tenant-1", display_name: "Grace", account_type: "human", role: "member", status: "active" } },
        { id: "membership-service", role: "member", joined_at: "2026-07-12T10:00:00Z", last_read_sequence: 0, user: { id: "service-1", tenant_id: "tenant-1", display_name: "Build bot", account_type: "service", role: "member", status: "active" } }
      ]),
      discoverPublicChannels: vi.fn().mockResolvedValue({ data: [], page: { limit: 25, has_more: false, next_cursor: null } }),
      searchMessagePage: vi.fn().mockResolvedValue({ data: [], page: { limit: 25, has_more: false, next_cursor: null } }),
      createModerationCase: vi.fn().mockResolvedValue({ id: "case-1" }),
      messageThread: vi.fn().mockResolvedValue({ data: { root: message(1), replies: [], reply_count: 0 }, page: { has_more: false, next_before_sequence: null } })
    });
  });

  it("keeps bare mobile app routes on the conversation list without clearing unread state", async () => {
    setMobileViewport(true);
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    expect(document.querySelector("main#main-content")).toHaveClass("mobile-list");
    expect(screen.getByLabelText("location-search")).toHaveTextContent("");
    expect(harness.api.messages).not.toHaveBeenCalled();
    expect(harness.markRead).not.toHaveBeenCalled();
  });

  it("opens a valid mobile conversation deep link directly in the message pane", async () => {
    setMobileViewport(true);
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages");
    expect(await screen.findByRole("button", { name: "Back to conversations" })).toBeInTheDocument();
    await waitFor(() => expect(harness.api.messages).toHaveBeenCalledWith("conversation-1", 0, 100));
  });

  it("pushes the selected mobile conversation and returns to a bare focused list", async () => {
    setMobileViewport(true);
    const user = userEvent.setup();
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );
    const conversationButton = within(screen.getByRole("navigation", { name: "Conversation list" }))
      .getByRole("button", { name: /General/ });

    await user.click(conversationButton);
    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent("?conversation=conversation-1"));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages");
    await waitFor(() => expect(screen.getByRole("button", { name: "Back to conversations" })).toHaveFocus());

    await user.click(screen.getByRole("button", { name: "Back to conversations" }));
    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent(""));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-list");
    await waitFor(() => expect(conversationButton).toHaveFocus());
  });

  it("synchronizes the mobile pane and focus when browser history returns to the list", async () => {
    setMobileViewport(true);
    const user = userEvent.setup();
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
        <HistoryBack />
      </MemoryRouter>
    );
    const conversationButton = within(screen.getByRole("navigation", { name: "Conversation list" }))
      .getByRole("button", { name: /General/ });

    await user.click(conversationButton);
    await waitFor(() => expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages"));
    await user.click(screen.getByRole("button", { name: "Browser back" }));

    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent(""));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-list");
    await waitFor(() => expect(conversationButton).toHaveFocus());
  });

  it("preserves desktop first-conversation auto-selection", async () => {
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent("?conversation=conversation-1"));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages");
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

  it("offers distinct audio and video calls from the message header when tenant policy enables them", async () => {
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);

    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Start video call" })).toBeVisible();
    expect(harness.api.audioCall).toHaveBeenCalledWith("conversation-1");
  });

  it("disables the audio action without probing calls when the media provider is unavailable", async () => {
    harness.audioCallsAvailable = false;
    harness.videoCallsAvailable = false;
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);

    expect(await screen.findByRole("button", { name: "Audio calls disabled" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Video calls disabled" })).toBeDisabled();
    expect(harness.api.audioCall).not.toHaveBeenCalled();
  });

  it("updates the audio call action immediately from conversation realtime events", async () => {
    const realtimeCall = {
      id: "call-1",
      conversation_id: "conversation-1",
      started_by_user_id: "user-2",
      status: "active" as const,
      started_at: "2026-07-15T10:00:00Z",
      expires_at: "2026-07-15T11:00:00Z",
      can_end: false
    };
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();

    harness.api.audioCall!.mockResolvedValue(realtimeCall);
    act(() => harness.callbacks?.onAudioCallStarted(realtimeCall));
    expect(await screen.findByRole("button", { name: "Join audio call" })).toBeVisible();

    act(() => harness.callbacks?.onAudioCallEnded({
      ...realtimeCall,
      status: "ended",
      ended_at: "2026-07-15T10:30:00Z",
      end_reason: "ended_by_user"
    }));
    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();
    expect(screen.getByText("The audio call was ended for everyone.")).toBeInTheDocument();
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

  it("turns a search result into a reloadable focused-message deep link", async () => {
    const user = userEvent.setup();
    const result = {
      ...message(42),
      id: "44444444-4444-4444-8444-444444444444"
    };
    harness.api.searchMessagePage!.mockResolvedValue({
      data: [result],
      page: { limit: 25, has_more: false, next_cursor: null }
    });

    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    await user.click(within(screen.getByLabelText("Conversations")).getByRole("button", { name: "Search messages" }));
    await user.type(screen.getByRole("searchbox", { name: "Search accessible messages" }), "Message 42");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await user.click(await screen.findByText("Message 42"));

    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent(
      "conversation=conversation-1&search_message=44444444-4444-4444-8444-444444444444&search_sequence=42"
    ));
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
