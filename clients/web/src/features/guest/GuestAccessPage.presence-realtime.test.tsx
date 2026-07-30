import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within
} from "@testing-library/react";
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
  ConversationMembership,
  GuestSession,
  Message,
  ReactionEvent
} from "../../types";
import {
  GuestAccessPage
} from "./GuestAccessPage";

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

  it("updates the participant list when a guest joins and leaves", async () => {
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    const selfMembership = {
      id: "member-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const joiningGuest = {
      id: "member-joining",
      role: "member" as const,
      joined_at: "2026-07-24T12:01:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "guest-2",
        display_name: "Jordan Guest"
      }
    };
    membersLookup.mockResolvedValue([selfMembership]);
    storeGuestSession(guestSession);
    renderPage();

    const roster = await screen.findByRole("list", { name: "Room participants" });
    expect(within(roster).getByText("Taylor", { exact: false })).toBeVisible();

    membersLookup.mockResolvedValue([selfMembership, joiningGuest]);
    act(() => {
      realtimeHarness.callbacks?.onPresence(
        2,
        [guestSession.user.id, joiningGuest.user.id]
      );
      realtimeHarness.callbacks?.onMembershipChanged();
    });

    expect(await within(roster).findByText("Jordan Guest")).toBeVisible();
    expect(screen.getByText("2 online · 2 total")).toBeVisible();
    act(() => {
      realtimeHarness.callbacks?.onMessages([
        message(50, joiningGuest.user.id)
      ]);
    });

    membersLookup.mockResolvedValue([selfMembership]);
    act(() => {
      realtimeHarness.callbacks?.onPresence(1, [guestSession.user.id]);
      realtimeHarness.callbacks?.onMembershipChanged();
    });

    await waitFor(() =>
      expect(within(roster).queryByText("Jordan Guest")).not.toBeInTheDocument()
    );
    expect(screen.getByText("1 online · 1 total")).toBeVisible();
    expect(
      within(document.querySelector(".guest-message-list") as HTMLElement)
        .getByText("Jordan Guest")
    ).toBeVisible();
  });

  it("reconciles an expired participant when only the Presence set changes", async () => {
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    const selfMembership = {
      id: "member-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const expiredMembership = {
      id: "member-expiring",
      role: "member" as const,
      joined_at: "2026-07-24T12:01:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "guest-expiring",
        display_name: "Expiring Guest"
      }
    };
    membersLookup.mockResolvedValue([selfMembership, expiredMembership]);
    storeGuestSession(guestSession);
    renderPage();

    const roster = await screen.findByRole("list", { name: "Room participants" });
    expect(await within(roster).findByText("Expiring Guest")).toBeVisible();
    act(() => {
      realtimeHarness.callbacks?.onPresence(
        2,
        [guestSession.user.id, expiredMembership.user.id]
      );
    });
    await waitFor(() => expect(screen.getByText("2 online · 2 total")).toBeVisible());

    const callsBeforeExpiry = membersLookup.mock.calls.length;
    membersLookup.mockResolvedValue([selfMembership]);
    act(() => {
      realtimeHarness.callbacks?.onPresence(1, [guestSession.user.id]);
      realtimeHarness.callbacks?.onPresence(1, [guestSession.user.id]);
    });

    await waitFor(() =>
      expect(membersLookup).toHaveBeenCalledTimes(callsBeforeExpiry + 1)
    );
    await waitFor(() =>
      expect(within(roster).queryByText("Expiring Guest")).not.toBeInTheDocument()
    );
    expect(screen.getByText("1 online · 1 total")).toBeVisible();
  });

  it("periodically reconciles an offline expiry without overlapping duplicate ticks", async () => {
    let reconcile: (() => void) | undefined;
    const intervalSpy = vi.spyOn(window, "setInterval").mockImplementation((handler, timeout) => {
      if (timeout === 30_000 && typeof handler === "function") {
        reconcile = handler as () => void;
      }
      return 42 as unknown as ReturnType<typeof window.setInterval>;
    });
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    const selfMembership = {
      id: "member-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const expiredMembership = {
      ...selfMembership,
      id: "member-offline-expired",
      user: {
        ...guestSession.user,
        id: "guest-offline-expired",
        display_name: "Offline Expired"
      }
    };
    membersLookup
      .mockResolvedValueOnce([selfMembership, expiredMembership])
      .mockResolvedValueOnce([selfMembership, expiredMembership])
      .mockResolvedValue([selfMembership]);
    storeGuestSession(guestSession);
    const view = renderPage();

    const roster = await screen.findByRole("list", {
      name: "Room participants"
    });
    expect(await within(roster).findByText("Offline Expired")).toBeVisible();
    await waitFor(() => expect(membersLookup.mock.calls.length).toBeGreaterThanOrEqual(2));
    const callsBeforeReconciliation = membersLookup.mock.calls.length;
    expect(reconcile).toBeTypeOf("function");

    act(() => {
      reconcile?.();
      reconcile?.();
    });

    await waitFor(() =>
      expect(membersLookup).toHaveBeenCalledTimes(
        callsBeforeReconciliation + 1
      )
    );
    await waitFor(() =>
      expect(within(roster).queryByText("Offline Expired"))
        .not.toBeInTheDocument()
    );
    view.unmount();
    intervalSpy.mockRestore();
  });

  it("reconciles the participant list after a realtime reconnect", async () => {
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    const selfMembership = {
      id: "member-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const joinedWhileOffline = {
      id: "member-offline-join",
      role: "member" as const,
      joined_at: "2026-07-24T12:02:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "guest-offline-join",
        display_name: "Offline Join"
      }
    };
    membersLookup.mockResolvedValue([selfMembership]);
    storeGuestSession(guestSession);
    renderPage();

    const roster = await screen.findByRole("list", { name: "Room participants" });
    expect(within(roster).queryByText("Offline Join")).not.toBeInTheDocument();

    membersLookup.mockResolvedValue([selfMembership, joinedWhileOffline]);
    act(() => {
      realtimeHarness.callbacks?.onStatus("reconnecting");
      realtimeHarness.callbacks?.onStatus("live");
    });

    expect(await within(roster).findByText("Offline Join")).toBeVisible();
  });

  it("does not let a stale initial member response replace a newer live reload", async () => {
    const selfMembership = {
      id: "member-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const liveMembership = {
      id: "member-live",
      role: "member" as const,
      joined_at: "2026-07-24T12:03:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "guest-live",
        display_name: "Live Reload"
      }
    };
    let resolveInitial:
      | ((members: ConversationMembership[]) => void)
      | undefined;
    let resolveLive:
      | ((members: ConversationMembership[]) => void)
      | undefined;
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    membersLookup
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveInitial = resolve;
      }))
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveLive = resolve;
      }));
    storeGuestSession(guestSession);

    renderPage();

    await waitFor(() => expect(membersLookup).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(screen.getByText("live", { selector: ".guest-connection" }))
        .toBeVisible()
    );
    await act(async () => {
      resolveInitial?.([selfMembership]);
      await Promise.resolve();
    });
    await waitFor(() => expect(membersLookup).toHaveBeenCalledTimes(2));
    await act(async () => {
      resolveLive?.([selfMembership, liveMembership]);
      await Promise.resolve();
    });
    const roster = screen.getByRole("list", { name: "Room participants" });
    expect(await within(roster).findByText("Live Reload")).toBeVisible();

    await screen.findByRole("textbox", { name: "Message" });
    expect(within(roster).getByText("Live Reload")).toBeVisible();
  });

  it("serializes membership reloads and applies the newest queued response", async () => {
    const membersLookup = vi.mocked(
      GuestApiClient.prototype.conversationMembers
    );
    const selfMembership = {
      id: "member-guest",
      role: "member" as const,
      joined_at: "2026-07-24T12:00:00Z",
      last_read_sequence: 0,
      user: guestSession.user
    };
    const newestMembership = {
      id: "member-newest",
      role: "member" as const,
      joined_at: "2026-07-24T12:04:00Z",
      last_read_sequence: 0,
      user: {
        ...guestSession.user,
        id: "guest-newest",
        display_name: "Newest Membership"
      }
    };
    storeGuestSession(guestSession);
    renderPage();
    const roster = await screen.findByRole("list", { name: "Room participants" });
    await within(roster).findByText("Taylor", { exact: false });

    let resolveOlder:
      | ((members: ConversationMembership[]) => void)
      | undefined;
    let resolveNewer:
      | ((members: ConversationMembership[]) => void)
      | undefined;
    membersLookup
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveOlder = resolve;
      }))
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveNewer = resolve;
      }));
    const callsBeforeEvents = membersLookup.mock.calls.length;
    act(() => {
      realtimeHarness.callbacks?.onMembershipChanged();
    });
    await waitFor(() =>
      expect(membersLookup).toHaveBeenCalledTimes(callsBeforeEvents + 1)
    );
    act(() => {
      realtimeHarness.callbacks?.onMembershipChanged();
    });
    await act(async () => {
      resolveOlder?.([selfMembership]);
      await Promise.resolve();
    });
    await waitFor(() =>
      expect(membersLookup).toHaveBeenCalledTimes(callsBeforeEvents + 2)
    );

    await act(async () => {
      resolveNewer?.([selfMembership, newestMembership]);
      await Promise.resolve();
    });
    expect(await within(roster).findByText("Newest Membership")).toBeVisible();
  });

  it("marks presence unknown off-line and restores it only after a fresh sync", async () => {
    storeGuestSession(guestSession);
    renderPage();
    const roster = await screen.findByRole("list", { name: "Room participants" });
    await within(roster).findByText("Taylor", { exact: false });
    const headerPresence = document.querySelector(".guest-room-heading p");
    expect(headerPresence).not.toHaveAttribute("role", "status");
    expect(headerPresence).not.toHaveAttribute("aria-live");
    const desktopConnection = document.querySelector(".guest-connection");
    expect(desktopConnection).toHaveAttribute("role", "status");
    expect(desktopConnection).toHaveAttribute("aria-live", "polite");
    expect(desktopConnection).toHaveAttribute("aria-atomic", "true");

    act(() => {
      realtimeHarness.callbacks?.onPresence(1, [guestSession.user.id]);
    });
    expect(within(roster).getByText("Online · Guest")).toBeVisible();

    act(() => {
      realtimeHarness.callbacks?.onStatus("reconnecting");
      realtimeHarness.callbacks?.onPresence(1, [guestSession.user.id]);
    });
    expect(screen.getByText("Presence unknown · 1 total")).toBeVisible();
    expect(within(roster).queryByText("Online · Guest")).not.toBeInTheDocument();

    act(() => {
      realtimeHarness.callbacks?.onStatus("live");
    });
    expect(screen.getByText("Presence unknown · 1 total")).toBeVisible();

    act(() => {
      realtimeHarness.callbacks?.onPresence(1, [guestSession.user.id]);
    });
    expect(within(roster).getByText("Online · Guest")).toBeVisible();
    expect(screen.getByText("1 online · 1 total")).toBeVisible();
  });

  it("does not send while an IME composition is being confirmed", async () => {
    const sendMessage = vi.spyOn(GuestApiClient.prototype, "sendMessage");
    storeGuestSession(guestSession);
    renderPage();
    const composer = await screen.findByRole("textbox", { name: "Message" });

    fireEvent.change(composer, { target: { value: "未確定" } });
    fireEvent.keyDown(composer, {
      key: "Enter",
      code: "Enter",
      isComposing: true
    });

    expect(sendMessage).not.toHaveBeenCalled();
    expect(composer).toHaveValue("未確定");
  });

  it("does not mark visible history read while the document is hidden", async () => {
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "hidden"
    });
    vi.spyOn(GuestApiClient.prototype, "messages").mockResolvedValue({
      data: [message(1)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    storeGuestSession(guestSession);
    renderPage();

    await screen.findByText("Message 1");
    await screen.findByLabelText("Guest call controls");
    expect(GuestApiClient.prototype.markRead).not.toHaveBeenCalled();

    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "visible"
    });
    await act(async () => {
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await waitFor(() =>
      expect(GuestApiClient.prototype.markRead).toHaveBeenCalledWith(1)
    );
  });
});
