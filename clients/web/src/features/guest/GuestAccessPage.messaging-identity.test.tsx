import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { BrowserRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiClient,
  ApiError,
  GuestApiClient,
  storeGuestSession
} from "../../api";
import { SessionProvider } from "../../app/session";
import type {
  Conversation,
  GuestSession,
  Message,
  ReactionEvent
} from "../../types";
import {
  GuestAccessPage
} from "./GuestAccessPage";
import { participantDisambiguator } from "../../lib/participantIdentity";

const realtimeHarness = vi.hoisted(() => ({
  callbacks: null as null | {
    onStatus: (status: string) => void;
    onMessages: (messages: Message[]) => void;
    onReactionAdded: (event: ReactionEvent) => void;
    onReactionRemoved: (event: ReactionEvent) => void;
    onMembershipChanged: () => void;
    onCatchUpRequired: (afterSequence: number) => void;
    onPresence: (count: number, userIds: string[]) => void;
  },
  tickets: [] as string[],
  disconnects: 0
}));

const transportHarness = vi.hoisted(() => ({
  insecureNetworkOrigin: false
}));

const callPanelHarness = vi.hoisted(() => ({
  props: null as null | {
    audioEnabled: boolean;
    videoEnabled: boolean;
    onOpenChat?: () => void;
  }
}));

vi.mock("../../lib/transportSecurity", () => ({
  isInsecureNonLoopbackOrigin: () => transportHarness.insecureNetworkOrigin
}));

vi.mock("../calls/CallPanel", () => ({
  CallPanel: (props: {
    audioEnabled: boolean;
    videoEnabled: boolean;
    onOpenChat?: () => void;
  }) => {
    callPanelHarness.props = props;
    return (
      <div aria-label="Guest call controls">
        Audio and video controls
        <button type="button" onClick={props.onOpenChat}>
          Open mocked room chat
        </button>
      </div>
    );
  }
}));

vi.mock("../../realtime", () => ({
  socketEndpoint: () => "/socket",
  RealtimeConversation: class {
    constructor(
      _endpoint: string,
      ticket: string,
      _conversationId: string,
      _afterSequence: () => number,
      private readonly callbacks: {
        onStatus: (status: string) => void;
        onMessages: (messages: Message[]) => void;
        onReactionAdded: (event: ReactionEvent) => void;
        onReactionRemoved: (event: ReactionEvent) => void;
        onMembershipChanged: () => void;
        onCatchUpRequired: (afterSequence: number) => void;
        onPresence: (count: number, userIds: string[]) => void;
      }
    ) {
      realtimeHarness.callbacks = callbacks;
      realtimeHarness.tickets.push(ticket);
    }
    connect() { this.callbacks.onStatus("live"); }
    disconnect() { realtimeHarness.disconnects += 1; }
    sendMessage() { return Promise.reject(new Error("not used")); }
  }
}));

const conversation: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "group",
  title: "Launch room",
  counterpart_user_id: null,
  counterpart_display_name: null,
  visibility: "private",
  latest_sequence: 0,
  membership_role: "member",
  inserted_at: "2026-07-24T12:00:00Z",
  updated_at: "2026-07-24T12:00:00Z"
};

const guestSession: GuestSession = {
  access_token: "guest-access",
  refresh_token: "guest-refresh",
  token_type: "Bearer",
  expires_in: 900,
  tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" },
  user: {
    id: "guest-1",
    tenant_id: "tenant-1",
    display_name: "Taylor",
    account_type: "guest",
    role: "member",
    status: "active"
  },
  device: {
    id: "device-1",
    user_id: "guest-1",
    name: "Browser",
    platform: "web"
  },
  conversation,
  capabilities: {
    allow_audio_calls: true,
    allow_video_calls: true,
    conversion_enabled: true,
    email_hint: "t***@example.test"
  }
};

function message(sequence: number, senderUserId = "member-2"): Message {
  return {
    id: `message-${sequence}`,
    tenant_id: "tenant-1",
    conversation_id: conversation.id,
    sender_user_id: senderUserId,
    sender_device_id: "device-2",
    client_message_id: `client-message-${sequence}`,
    conversation_sequence: sequence,
    body: `Message ${sequence}`,
    metadata: {},
    status: "active",
    inserted_at: `2026-07-24T12:${String(sequence % 60).padStart(2, "0")}:00Z`,
    attachments: [],
    reactions: []
  };
}

function renderPage(strict = false) {
  const page = (
    <SessionProvider>
      <BrowserRouter>
        <GuestAccessPage />
      </BrowserRouter>
    </SessionProvider>
  );
  return render(strict ? <StrictMode>{page}</StrictMode> : page);
}

function setMobileRoomLayout(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches: query === "(max-width: 760px), (max-height: 560px)"
        ? matches
        : false,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  });
}

describe("GuestAccessPage", () => {
  beforeEach(() => {
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/join");
    realtimeHarness.callbacks = null;
    realtimeHarness.tickets = [];
    realtimeHarness.disconnects = 0;
    transportHarness.insecureNetworkOrigin = false;
    callPanelHarness.props = null;
    setMobileRoomLayout(false);
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "visible"
    });
    vi.restoreAllMocks();
    vi.spyOn(ApiClient.prototype, "status").mockResolvedValue({
      service: "k-comms",
      version: "test",
      status: "operational",
      capabilities: {
        administration: true,
        audio_calls: true,
        video_calls: true,
        attachment_scanning: true,
        bootstrap: false,
        guest_links: true,
        instant_rooms: true,
        notifications: true,
        push_notifications: true,
        realtime: true,
        secure_account_actions: true,
        secure_media_actions: true,
        webhooks: true
      }
    });
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockRejectedValue(
      new ApiError(404, "instant_room_not_found", "Not an instant-room link")
    );
    vi.spyOn(GuestApiClient.prototype, "conversation").mockResolvedValue(conversation);
    vi.spyOn(GuestApiClient.prototype, "conversationMembers").mockResolvedValue([
      {
        id: "member-1",
        role: "member",
        joined_at: "2026-07-24T12:00:00Z",
        last_read_sequence: 0,
        user: guestSession.user
      }
    ]);
    vi.spyOn(GuestApiClient.prototype, "messages").mockResolvedValue({
      data: [] as Message[],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    vi.spyOn(GuestApiClient.prototype, "messageSenderLabels").mockResolvedValue([]);
    vi.spyOn(GuestApiClient.prototype, "socketTicket").mockResolvedValue({
      ticket: "socket-ticket",
      expires_in: 60
    });
    vi.spyOn(GuestApiClient.prototype, "markRead").mockResolvedValue(undefined);
    vi.spyOn(GuestApiClient.prototype, "logout").mockResolvedValue(undefined);
  });

  it("keeps unread realtime messages available when scrolled up and marks them read only at the bottom", async () => {
    storeGuestSession(guestSession);
    renderPage();
    const composer = await screen.findByRole("textbox", { name: "Message" });
    const scroll = document.querySelector(".guest-message-scroll") as HTMLDivElement;
    Object.defineProperties(scroll, {
      scrollHeight: { configurable: true, value: 1_000 },
      clientHeight: { configurable: true, value: 200 },
      scrollTop: { configurable: true, value: 100, writable: true }
    });
    fireEvent.scroll(scroll);

    act(() => realtimeHarness.callbacks?.onMessages([message(1)]));

    expect(
      await screen.findByRole("button", {
        name: "1 new message · Jump to latest"
      })
    ).toBeVisible();
    expect(GuestApiClient.prototype.markRead).not.toHaveBeenCalledWith(1);

    scroll.scrollTop = 800;
    fireEvent.scroll(scroll);
    await waitFor(() =>
      expect(GuestApiClient.prototype.markRead).toHaveBeenCalledWith(1)
    );
    expect(
      screen.queryByRole("button", {
        name: "1 new message · Jump to latest"
      })
    ).not.toBeInTheDocument();
    expect(composer).toHaveFocus();
  });

  it("retains composer focus while a message send is pending", async () => {
    const user = userEvent.setup();
    let resolveSend: ((value: Message) => void) | undefined;
    vi.spyOn(GuestApiClient.prototype, "sendMessage").mockReturnValue(
      new Promise((resolve) => {
        resolveSend = resolve;
      })
    );
    storeGuestSession(guestSession);
    renderPage();
    const composer = await screen.findByRole("textbox", { name: "Message" });

    await user.type(composer, "Focus stays here");
    await user.keyboard("{Enter}");

    expect(composer).toHaveFocus();
    expect(composer).toHaveAttribute("readonly");
    expect(screen.getByRole("button", { name: "Sending message" })).toHaveAttribute(
      "aria-busy",
      "true"
    );
    act(() => resolveSend?.(message(1, guestSession.user.id)));
    await waitFor(() => expect(composer).not.toHaveAttribute("readonly"));
    expect(composer).toHaveFocus();
    expect(screen.getByRole("button", { name: "Send" })).toHaveAttribute(
      "aria-busy",
      "false"
    );
  });

  it("shows live participants and uses the same display names in chat", async () => {
    const host = {
      id: "member-host",
      role: "owner" as const,
      joined_at: "2026-07-24T11:00:00Z",
      last_read_sequence: 0,
      user: {
        id: "member-2",
        tenant_id: "tenant-1",
        display_name: "Ada Host",
        account_type: "human" as const,
        role: "owner" as const,
        status: "active"
      }
    };
    vi.mocked(GuestApiClient.prototype.conversationMembers).mockResolvedValue([
      {
        id: "member-guest",
        role: "member",
        joined_at: "2026-07-24T12:00:00Z",
        last_read_sequence: 0,
        user: guestSession.user
      },
      host
    ]);
    vi.mocked(GuestApiClient.prototype.messages).mockResolvedValue({
      data: [message(1), message(2, guestSession.user.id)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);

    renderPage();

    const roster = await screen.findByRole("list", { name: "Room participants" });
    act(() => realtimeHarness.callbacks?.onPresence(
      2,
      [guestSession.user.id, host.user.id]
    ));
    expect(await within(roster).findByText("Taylor", { exact: false }))
      .toHaveTextContent("Taylor (you)");
    expect(within(roster).getByText("Ada Host")).toBeVisible();
    expect(screen.getByText("2 online · 2 total")).toBeVisible();

    const messageList = document.querySelector(".guest-message-list");
    expect(messageList).not.toBeNull();
    expect(within(messageList as HTMLElement).getByText("Ada Host")).toBeVisible();
    expect(
      within(messageList as HTMLElement).getByText("Taylor (you)")
    ).toBeVisible();
  });

  it("restores a departed sender username from the authorized history sidecar", async () => {
    vi.mocked(GuestApiClient.prototype.conversationMembers).mockResolvedValue([
      {
        id: "member-guest",
        role: "member",
        joined_at: "2026-07-24T12:00:00Z",
        last_read_sequence: 0,
        user: guestSession.user
      }
    ]);
    vi.mocked(GuestApiClient.prototype.messages).mockResolvedValue({
      data: [message(9, "departed-guest")],
      included: {
        sender_labels: [
          { id: "departed-guest", display_name: "Jordan Departed", redacted: false }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);

    renderPage();

    const roster = await screen.findByRole("list", {
      name: "Room participants"
    });
    expect(within(roster).queryByText("Jordan Departed")).not.toBeInTheDocument();

    const messageList = document.querySelector(".guest-message-list");
    expect(messageList).not.toBeNull();
    expect(
      await within(messageList as HTMLElement).findByText("Jordan Departed")
    ).toBeVisible();
  });

  it("replaces a departed guest cache with the erased history sidecar label", async () => {
    const activeGuest = {
      id: "member-erased-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:01:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "erased-guest",
        display_name: "Avery Active Guest"
      }
    };
    const selfMembership = {
      id: "member-self",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    membersLookup.mockResolvedValue([selfMembership, activeGuest]);
    const guestMessage = {
      ...message(52, activeGuest.user.id),
      body: "Message before guest erasure"
    };
    const messagesLookup = vi.mocked(GuestApiClient.prototype.messages);
    messagesLookup.mockResolvedValue({
      data: [message(51, guestSession.user.id)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);
    renderPage();

    const roster = await screen.findByRole("list", {
      name: "Room participants"
    });
    expect(await within(roster).findByText("Avery Active Guest")).toBeVisible();
    await waitFor(() => expect(membersLookup.mock.calls.length).toBeGreaterThanOrEqual(2));
    act(() => realtimeHarness.callbacks?.onMessages([guestMessage]));
    expect(await screen.findByText("Message before guest erasure")).toBeVisible();
    vi.mocked(GuestApiClient.prototype.messageSenderLabels).mockResolvedValue([
      { id: activeGuest.user.id, display_name: "Deleted user", redacted: true }
    ]);
    membersLookup.mockResolvedValue([selfMembership]);

    act(() => realtimeHarness.callbacks?.onMembershipChanged());

    expect(await screen.findByText("Deleted user")).toBeVisible();
    expect(within(roster).queryByText("Avery Active Guest")).not.toBeInTheDocument();
    expect(screen.queryByText("Avery Active Guest")).not.toBeInTheDocument();
    expect(GuestApiClient.prototype.messageSenderLabels).toHaveBeenCalledWith([
      guestMessage.id
    ]);
  });

  it("refreshes an erased guest older than 200 rendered messages without replaying history", async () => {
    const selfMembership = {
      id: "member-self",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const oldAuthorMembership = {
      ...selfMembership,
      id: "member-old-author",
      user: {
        ...guestSession.user,
        id: "old-guest-author",
        display_name: "Old Guest Before Erasure"
      }
    };
    const renderedMessages = [
      {
        ...message(1, oldAuthorMembership.user.id),
        body: "Old guest message remains visible"
      },
      ...Array.from(
        { length: 200 },
        (_, index) => message(index + 2, guestSession.user.id)
      )
    ];
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    membersLookup.mockResolvedValue([
      selfMembership,
      oldAuthorMembership
    ]);
    const messagesLookup = vi.mocked(GuestApiClient.prototype.messages);
    messagesLookup.mockResolvedValue({
      data: renderedMessages,
      included: {
        sender_labels: [
          {
            id: oldAuthorMembership.user.id,
            display_name: oldAuthorMembership.user.display_name,
            redacted: false
          }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);
    renderPage();

    const oldMessageBody = await screen.findByText(
      "Old guest message remains visible"
    );
    const messageList = oldMessageBody.closest(".guest-message-list");
    expect(messageList).not.toBeNull();
    expect(
      within(messageList as HTMLElement)
        .getByText("Old Guest Before Erasure")
    ).toBeVisible();
    await waitFor(() => expect(membersLookup.mock.calls.length).toBeGreaterThanOrEqual(2));
    vi.mocked(GuestApiClient.prototype.messageSenderLabels).mockResolvedValue([
      {
        id: oldAuthorMembership.user.id,
        display_name: "Deleted user",
        redacted: true
      }
    ]);
    membersLookup.mockResolvedValue([selfMembership]);

    act(() => realtimeHarness.callbacks?.onMembershipChanged());

    expect(await screen.findByText("Deleted user")).toBeVisible();
    expect(screen.queryByText("Old Guest Before Erasure")).not.toBeInTheDocument();
    expect(GuestApiClient.prototype.messageSenderLabels).toHaveBeenCalledWith([
      "message-1"
    ]);
    expect(messagesLookup).toHaveBeenCalledTimes(1);
  });

  it("skips hidden sender-label refreshes and backs off unchanged labels until a change resets the delay", async () => {
    let now = 0;
    const nowSpy = vi.spyOn(Date, "now").mockImplementation(() => now);
    const selfMembership = {
      id: "member-self",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const departedMembership = {
      ...selfMembership,
      id: "member-adaptive-departed",
      user: {
        ...guestSession.user,
        id: "adaptive-departed-guest",
        display_name: "Former guest"
      }
    };
    const departedMessage = {
      ...message(61, departedMembership.user.id),
      body: "Adaptive guest sender label"
    };
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    membersLookup.mockResolvedValue([
      selfMembership,
      departedMembership
    ]);
    vi.mocked(GuestApiClient.prototype.messages).mockResolvedValue({
      data: [departedMessage],
      included: {
        sender_labels: [
          {
            id: departedMembership.user.id,
            display_name: "Former guest",
            redacted: false
          }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    const senderLabelsLookup = vi.mocked(
      GuestApiClient.prototype.messageSenderLabels
    );
    senderLabelsLookup
      .mockResolvedValueOnce([
        {
          id: departedMembership.user.id,
          display_name: "Former guest",
          redacted: false
        }
      ])
      .mockResolvedValueOnce([
        {
          id: departedMembership.user.id,
          display_name: "Former guest",
          redacted: false
        }
      ])
      .mockResolvedValue([
        {
          id: departedMembership.user.id,
          display_name: "Renamed guest",
          redacted: false
        }
      ]);
    storeGuestSession(guestSession);
    renderPage();
    await screen.findByText("Adaptive guest sender label");
    await waitFor(() => expect(realtimeHarness.callbacks).not.toBeNull());
    membersLookup.mockResolvedValue([selfMembership]);

    const reconcile = async () => {
      const expectedMemberCalls = membersLookup.mock.calls.length + 1;
      act(() => realtimeHarness.callbacks?.onMembershipChanged());
      await waitFor(() =>
        expect(membersLookup).toHaveBeenCalledTimes(expectedMemberCalls)
      );
      await act(async () => {
        await new Promise((resolve) => window.setTimeout(resolve, 0));
      });
    };

    await reconcile();
    await waitFor(() => expect(senderLabelsLookup).toHaveBeenCalledTimes(1));

    now = 30_000;
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "hidden"
    });
    await reconcile();
    expect(senderLabelsLookup).toHaveBeenCalledTimes(1);

    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "visible"
    });
    await reconcile();
    await waitFor(() => expect(senderLabelsLookup).toHaveBeenCalledTimes(2));

    now = 60_000;
    await reconcile();
    expect(senderLabelsLookup).toHaveBeenCalledTimes(2);

    now = 90_000;
    await reconcile();
    await waitFor(() => expect(senderLabelsLookup).toHaveBeenCalledTimes(3));
    expect(await screen.findByText("Renamed guest")).toBeVisible();

    now = 120_000;
    await reconcile();
    await waitFor(() => expect(senderLabelsLookup).toHaveBeenCalledTimes(4));
    nowSpy.mockRestore();
  });

  it("keeps an ordinary departed guest named when the sidecar retains no override", async () => {
    const activeGuest = {
      id: "member-ordinary-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:01:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "ordinary-guest",
        display_name: "Jordan Ordinary Guest"
      }
    };
    const selfMembership = {
      id: "member-self",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    membersLookup.mockResolvedValue([selfMembership, activeGuest]);
    const guestMessage = {
      ...message(52, activeGuest.user.id),
      body: "Ordinary departed message"
    };
    const messagesLookup = vi.mocked(GuestApiClient.prototype.messages);
    messagesLookup.mockResolvedValue({
      data: [message(51, guestSession.user.id)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);
    renderPage();

    await screen.findByText("Jordan Ordinary Guest");
    await waitFor(() => expect(membersLookup.mock.calls.length).toBeGreaterThanOrEqual(2));
    act(() => realtimeHarness.callbacks?.onMessages([guestMessage]));
    expect(await screen.findByText("Ordinary departed message")).toBeVisible();
    membersLookup.mockResolvedValue([selfMembership]);

    act(() => realtimeHarness.callbacks?.onMembershipChanged());

    await waitFor(() =>
      expect(GuestApiClient.prototype.messageSenderLabels).toHaveBeenCalledWith([
        guestMessage.id
      ])
    );
    expect(screen.getByText("Jordan Ordinary Guest")).toBeVisible();
    expect(screen.getByText("Ordinary departed message")).toBeVisible();
  });

  it("reconciles socket replay through guest REST history without duplicating it", async () => {
    const replayed = {
      ...message(2, "departed-replay-guest"),
      body: "Replayed guest message"
    };
    const messagesLookup = vi.mocked(GuestApiClient.prototype.messages);
    messagesLookup
      .mockResolvedValueOnce({
        data: [message(1, guestSession.user.id)],
        page: {
          has_more: false,
          next_after_sequence: null,
          reset_required: false
        }
      })
      .mockResolvedValueOnce({
        data: [replayed],
        included: {
          sender_labels: [
            {
              id: replayed.sender_user_id,
              display_name: "Jordan Replay",
              redacted: false
            }
          ]
        },
        page: {
          has_more: false,
          next_after_sequence: null,
          reset_required: false
        }
      });
    storeGuestSession(guestSession);
    renderPage();
    await screen.findByText("Message 1");
    await waitFor(() => expect(realtimeHarness.callbacks).not.toBeNull());

    act(() => {
      realtimeHarness.callbacks?.onMessages([replayed]);
      realtimeHarness.callbacks?.onCatchUpRequired(1);
    });

    expect(await screen.findByText("Jordan Replay")).toBeVisible();
    expect(screen.getAllByText("Replayed guest message")).toHaveLength(1);
    expect(messagesLookup).toHaveBeenCalledWith(1, 200);
  });

  it("disambiguates duplicate usernames restored only from retained history", async () => {
    vi.mocked(GuestApiClient.prototype.conversationMembers).mockResolvedValue([
      {
        id: "member-guest",
        role: "member",
        joined_at: "2026-07-24T12:00:00Z",
        last_read_sequence: 0,
        user: guestSession.user
      }
    ]);
    vi.mocked(GuestApiClient.prototype.messages).mockResolvedValue({
      data: [
        message(9, "departed-alex-1"),
        message(10, "departed-alex-2")
      ],
      included: {
        sender_labels: [
          { id: "departed-alex-1", display_name: "Alex", redacted: false },
          { id: "departed-alex-2", display_name: "ALEX", redacted: false }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);

    renderPage();

    await screen.findByText("Message 9");
    const messageList = document.querySelector(".guest-message-list");
    expect(messageList).not.toBeNull();
    const scoped = within(messageList as HTMLElement);
    expect(
      await scoped.findByText(
        `Alex · #${participantDisambiguator("departed-alex-1")}`
      )
    ).toBeVisible();
    expect(
      scoped.getByText(
        `ALEX · #${participantDisambiguator("departed-alex-2")}`
      )
    ).toBeVisible();
  });

  it("adds stable identifiers to duplicate participant names in chat", async () => {
    const duplicate = {
      id: "member-duplicate",
      role: "member" as const,
      joined_at: "2026-07-24T12:01:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "guest-duplicate",
        display_name: "TAYLOR"
      }
    };
    vi.mocked(GuestApiClient.prototype.conversationMembers).mockResolvedValue([
      {
        id: "member-guest",
        role: "member",
        joined_at: "2026-07-24T12:00:00Z",
        last_read_sequence: 0,
        user: guestSession.user
      },
      duplicate
    ]);
    vi.mocked(GuestApiClient.prototype.messages).mockResolvedValue({
      data: [
        message(10, guestSession.user.id),
        message(11, duplicate.user.id)
      ],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);

    renderPage();

    await screen.findByText("Message 10");
    const messageList = document.querySelector(".guest-message-list");
    expect(messageList).not.toBeNull();
    const scoped = within(messageList as HTMLElement);
    expect(
      await scoped.findByText(
        `Taylor · #${participantDisambiguator(guestSession.user.id)} (you)`
      )
    ).toBeVisible();
    expect(
      scoped.getByText(
        `TAYLOR · #${participantDisambiguator(duplicate.user.id)}`
      )
    ).toBeVisible();
  });

  it("uses the active roster to disambiguate a sender before their namesake writes", async () => {
    const silentNamesake = {
      id: "member-silent-namesake",
      role: "member" as const,
      joined_at: "2026-07-24T12:01:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "guest-silent-namesake",
        display_name: "TAYLOR"
      }
    };
    vi.mocked(GuestApiClient.prototype.conversationMembers).mockResolvedValue([
      {
        id: "member-guest",
        role: "member",
        joined_at: "2026-07-24T12:00:00Z",
        last_read_sequence: 0,
        user: guestSession.user
      },
      silentNamesake
    ]);
    vi.mocked(GuestApiClient.prototype.messages).mockResolvedValue({
      data: [message(12, guestSession.user.id)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);

    renderPage();

    await screen.findByText("Message 12");
    const messageList = document.querySelector(".guest-message-list");
    expect(messageList).not.toBeNull();
    const senderCode = participantDisambiguator(guestSession.user.id);
    expect(
      await within(messageList as HTMLElement).findByText(
        `Taylor · #${senderCode} (you)`
      )
    ).toBeVisible();

    const roster = screen.getByRole("list", { name: "Room participants" });
    expect(roster).toHaveTextContent(`Taylor · #${senderCode} (you)`);
    expect(roster).toHaveTextContent(
      `TAYLOR · #${participantDisambiguator(silentNamesake.user.id)}`
    );
  });
});
