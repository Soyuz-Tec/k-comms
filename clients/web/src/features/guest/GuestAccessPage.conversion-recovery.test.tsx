import {
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
  storeSession,
  storeGuestSession
} from "../../api";
import { SessionProvider, useSession } from "../../app/session";
import type {
  Conversation,
  GuestSession,
  Message,
  ReactionEvent,
  Session
} from "../../types";
import {
  GuestAccessPage,
  GuestShell
} from "./GuestAccessPage";
import { storeMemberInstantRoomContinuity } from "../instant-room/memberContinuity";

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
  isEncryptedUrl: () => false,
  isInsecureNonLoopbackOrigin: () => transportHarness.insecureNetworkOrigin
}));

vi.mock("../whiteboard/CollaborativeWhiteboard", () => ({
  CollaborativeWhiteboard: () => (
    <div aria-label="Mock shared canvas">Shared canvas ready</div>
  )
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

function SessionLossControl() {
  const { setSession } = useSession();
  return (
    <button type="button" onClick={() => setSession(null)}>
      Expire member session
    </button>
  );
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

  it("converts the guest in place and preserves the conversation route", async () => {
    const user = userEvent.setup();
    storeGuestSession(guestSession);
    const accountSession: Session = {
      ...guestSession,
      user: {
        ...guestSession.user,
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    const convertAccount = vi.spyOn(GuestApiClient.prototype, "convertAccount")
      .mockResolvedValue({ session: accountSession, conversation });

    renderPage();

    const accountToggle = await screen.findByRole("button", {
      name: "Keep this conversation"
    });
    expect(accountToggle).toHaveAttribute("aria-expanded", "false");
    await user.click(accountToggle);
    expect(accountToggle).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText(/t\*\*\*@example\.test/)).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Work email" })).toHaveFocus();
    await user.click(screen.getByRole("button", { name: "Not now" }));
    await waitFor(() => expect(accountToggle).toHaveFocus());
    await user.click(accountToggle);
    await user.type(screen.getByRole("textbox", { name: "Work email" }), "taylor@example.test");
    await user.type(
      screen.getByRole("textbox", { name: "Account verification code" }),
      "V".repeat(43)
    );
    await user.type(screen.getByLabelText(/^Password/), "correct horse battery staple");
    const accountForm = screen.getByRole("heading", { name: "Keep your conversation" })
      .closest("section")?.querySelector("form");
    expect(accountForm).not.toBeNull();
    await user.click(within(accountForm as HTMLFormElement).getByRole("button", { name: "Create account" }));

    await waitFor(() => expect(convertAccount).toHaveBeenCalledWith({
      email: "taylor@example.test",
      verification_code: "V".repeat(43),
      password: "correct horse battery staple"
    }));
    await waitFor(() => expect(window.location.pathname).toBe("/app/"));
    expect(window.location.search).toBe("?conversation=conversation-1");
    expect(window.sessionStorage.getItem("k-comms.guest-session.v1")).toBeNull();
  });

  it("hands realtime to the converted identity without unmounting room history", async () => {
    const user = userEvent.setup();
    const selfServiceSession: GuestSession = {
      ...guestSession,
      capabilities: {
        ...guestSession.capabilities,
        self_service_conversion: true
      }
    };
    vi.spyOn(GuestApiClient.prototype, "messages").mockResolvedValue({
      data: [message(1)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    const convertedSession: Session = {
      ...selfServiceSession,
      user: {
        ...selfServiceSession.user,
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    const convertAccount = vi
      .spyOn(GuestApiClient.prototype, "convertAccount")
      .mockResolvedValue({
        session: convertedSession,
        conversation,
        socket_handoff: {
          ticket: "converted-socket-ticket",
          expires_in: 60
        }
      });
    const onConverted = vi.fn();
    const api = new GuestApiClient("", selfServiceSession, vi.fn());

    render(
      <BrowserRouter>
        <GuestShell
          api={api}
          initialSession={selfServiceSession}
          accountActionsAllowed
          mediaActionsAllowed
          onLeave={vi.fn()}
          onConverted={onConverted}
          roomBanner={<div>Share controls remain mounted</div>}
          identityLabel="Host"
        />
      </BrowserRouter>
    );

    expect(await screen.findByText("Message 1")).toBeVisible();
    expect(screen.getByRole("link", { name: "Sign in" })).toHaveAttribute(
      "href",
      "/sign-in"
    );
    expect(screen.getByRole("textbox", { name: "Message" })).not.toHaveFocus();
    await waitFor(() =>
      expect(realtimeHarness.tickets).toEqual(["socket-ticket"])
    );
    await user.click(screen.getByRole("button", { name: "Save this room" }));
    await user.clear(screen.getByRole("textbox", { name: /Display name/ }));
    await user.type(
      screen.getByRole("textbox", { name: /Display name/ }),
      "Taylor Human"
    );
    await user.type(
      await screen.findByRole("textbox", { name: "Work email" }),
      "taylor@example.test"
    );
    await user.type(
      screen.getByLabelText(/^Password/),
      "correct horse battery staple"
    );
    await user.click(
      within(
        screen.getByRole("heading", { name: "Keep your conversation" })
          .closest("section") as HTMLElement
      ).getByRole("button", { name: "Create account" })
    );

    await waitFor(() =>
      expect(realtimeHarness.tickets).toEqual([
        "socket-ticket",
        "converted-socket-ticket"
      ])
    );
    expect(convertAccount).toHaveBeenCalledWith({
      email: "taylor@example.test",
      password: "correct horse battery staple",
      display_name: "Taylor Human"
    });
    expect(onConverted).toHaveBeenCalledWith(
      convertedSession,
      conversation,
      { ticket: "converted-socket-ticket", expires_in: 60 }
    );
    expect(realtimeHarness.disconnects).toBeGreaterThan(0);
    expect(
      screen.getByText(/Account created for Taylor/i)
    ).toBeInTheDocument();
    expect(
      screen.getByRole("region", {
        name: `Room saved for ${convertedSession.user.display_name}`
      })
    ).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Workspace address" })).toHaveValue(
      selfServiceSession.tenant.slug
    );
    expect(
      screen.getByRole("link", { name: "Workspace sign-in link" })
    ).toHaveAttribute(
      "href",
      `/sign-in?tenant_slug=${encodeURIComponent(
        selfServiceSession.tenant.slug
      )}`
    );
    expect(
      screen.queryByRole("button", { name: "Save this room" })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: "Message" })).toHaveFocus();
    expect(screen.getByText("Message 1")).toBeVisible();
    expect(screen.getByText("Share controls remain mounted")).toBeVisible();
  });

  it("keeps an instant-room recipient on the same route after self-service upgrade", async () => {
    const user = userEvent.setup();
    const instantGuest: GuestSession = {
      ...guestSession,
      instant_room: {
        id: "instant-room-1",
        conversation_id: conversation.id,
        owner_user_id: "guest-1",
        owner_kind: "guest",
        status: "active",
        participant_limit: 25,
        idle_since: null,
        expires_at: null,
        inserted_at: "2026-07-24T12:00:00Z",
        updated_at: "2026-07-24T12:00:00Z"
      },
      capabilities: {
        ...guestSession.capabilities,
        self_service_conversion: true
      }
    };
    storeGuestSession(instantGuest);
    const convertedSession: Session = {
      ...instantGuest,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...instantGuest.user,
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    vi.spyOn(GuestApiClient.prototype, "convertAccount").mockResolvedValue({
      session: convertedSession,
      conversation,
      socket_handoff: {
        ticket: "recipient-handoff-ticket",
        expires_in: 60
      }
    });

    renderPage();

    await user.click(
      await screen.findByRole("button", { name: "Open room controls" })
    );
    await user.click(
      within(screen.getByRole("dialog", { name: "Launch room" }))
        .getByRole("button", { name: /Keep this conversation/ })
    );
    await user.type(
      await screen.findByRole("textbox", { name: "Work email" }),
      "taylor@example.test"
    );
    await user.type(
      screen.getByLabelText(/^Password/),
      "correct horse battery staple"
    );
    await user.click(
      within(
        screen.getByRole("heading", { name: "Keep your conversation" })
          .closest("section") as HTMLElement
      ).getByRole("button", { name: "Create account" })
    );

    await waitFor(() =>
      expect(
        screen.queryByRole("button", { name: "Keep this conversation" })
      ).not.toBeInTheDocument()
    );
    expect(window.location.pathname).toBe("/join");
    expect(screen.getByRole("textbox", { name: "Message" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Open room controls" }));
    expect(
      within(screen.getByRole("dialog", { name: "Launch room" }))
        .getByText("Member", { selector: ".guest-badge" })
    ).toBeVisible();
    expect(
      screen.queryByText(/You joined as a guest/i)
    ).not.toBeInTheDocument();
    expect(screen.getByText(/Your room is ready/i)).toBeVisible();
    expect(window.sessionStorage.getItem("k-comms.guest-session.v1")).toBeNull();
    expect(
      window.sessionStorage.getItem("k-comms.session.v1")
    ).toContain("member-access");
    expect(realtimeHarness.tickets).toContain("recipient-handoff-ticket");
  });

  it("redirects a converted instant-room participant back to the same member conversation after remount", async () => {
    const user = userEvent.setup();
    const token = "A".repeat(43);
    const instantGuest: GuestSession = {
      ...guestSession,
      instant_room: {
        id: "instant-room-1",
        conversation_id: conversation.id,
        owner_user_id: "room-host-1",
        owner_kind: "guest",
        status: "active",
        participant_limit: 25,
        idle_since: null,
        expires_at: null,
        inserted_at: "2026-07-24T12:00:00Z",
        updated_at: "2026-07-24T12:00:00Z"
      },
      capabilities: {
        ...guestSession.capabilities,
        self_service_conversion: true
      }
    };
    const convertedSession: Session = {
      ...instantGuest,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...instantGuest.user,
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockResolvedValue({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    vi.spyOn(GuestApiClient.prototype, "joinInstantRoom")
      .mockResolvedValue(instantGuest);
    vi.spyOn(GuestApiClient.prototype, "convertAccount").mockResolvedValue({
      session: convertedSession,
      conversation,
      socket_handoff: {
        ticket: "recipient-handoff-ticket",
        expires_in: 60
      }
    });
    const memberConversation = vi
      .spyOn(ApiClient.prototype, "conversation")
      .mockResolvedValue(conversation);
    window.history.replaceState({}, "", `/join#guest=${token}`);

    const first = renderPage();
    await user.type(
      await screen.findByRole("textbox", { name: "Your display name" }),
      "Taylor"
    );
    await user.click(
      screen.getByRole("button", { name: "Join conversation" })
    );
    await user.click(
      await screen.findByRole("button", { name: "Open room controls" })
    );
    await user.click(
      within(screen.getByRole("dialog", { name: "Launch room" }))
        .getByRole("button", { name: /Keep this conversation/ })
    );
    await user.type(
      await screen.findByRole("textbox", { name: "Work email" }),
      "taylor@example.test"
    );
    await user.type(
      screen.getByLabelText(/^Password/),
      "correct horse battery staple"
    );
    await user.click(
      within(
        screen.getByRole("heading", { name: "Keep your conversation" })
          .closest("section") as HTMLElement
      ).getByRole("button", { name: "Create account" })
    );
    await waitFor(() =>
      expect(
        window.sessionStorage.getItem("k-comms.member-instant-room.v1")
      ).toContain(conversation.id)
    );
    const stored =
      window.sessionStorage.getItem("k-comms.member-instant-room.v1") || "";
    expect(stored).toContain(`#guest=${token}`);
    expect(stored).not.toContain("guest-access");
    expect(stored).not.toContain("guest-refresh");
    first.unmount();
    window.history.replaceState({}, "", "/join");

    renderPage();

    await waitFor(() => expect(window.location.pathname).toBe("/app/"));
    expect(window.location.search).toBe(
      `?conversation=${encodeURIComponent(conversation.id)}`
    );
    expect(memberConversation).toHaveBeenCalledWith(conversation.id);
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
    ).toBeNull();
  });

  it("recovers from a lost member session while room continuity is still reopening", async () => {
    const user = userEvent.setup();
    const token = "A".repeat(43);
    const accountSession: Session = {
      ...guestSession,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...guestSession.user,
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    const room = {
      id: "instant-room-1",
      conversation_id: conversation.id,
      owner_user_id: accountSession.user.id,
      owner_kind: "registered" as const,
      status: "active" as const,
      participant_limit: 25,
      idle_since: null,
      expires_at: null,
      inserted_at: "2026-07-24T12:00:00Z",
      updated_at: "2026-07-24T12:00:00Z"
    };
    storeSession(accountSession);
    expect(storeMemberInstantRoomContinuity(accountSession, {
      room,
      conversation,
      share_url: `https://comms.test/join#guest=${token}`
    })).toBe(true);
    vi.spyOn(ApiClient.prototype, "conversation").mockImplementation(
      () => new Promise<Conversation>(() => undefined)
    );

    render(
      <SessionProvider>
        <SessionLossControl />
        <BrowserRouter>
          <GuestAccessPage />
        </BrowserRouter>
      </SessionProvider>
    );

    expect(
      await screen.findByRole("heading", {
        name: "Reopening your conversation…"
      })
    ).toBeVisible();
    await user.click(
      screen.getByRole("button", { name: "Expire member session" })
    );

    expect(
      await screen.findByRole("link", { name: "Start new room" })
    ).toHaveAttribute("href", "/");
    expect(
      screen.queryByRole("heading", {
        name: "Reopening your conversation…"
      })
    ).not.toBeInTheDocument();
    expect(
      window.sessionStorage.getItem("k-comms.member-instant-room.v1")
    ).toBeNull();
  });

  it("fails closed when the guest session does not authorize account conversion", async () => {
    storeGuestSession({
      ...guestSession,
      capabilities: {
        allow_audio_calls: true,
        allow_video_calls: true
      }
    });

    renderPage();

    expect(await screen.findByRole("textbox", { name: "Message" })).toBeVisible();
    expect(
      screen.queryByRole("button", { name: "Keep this conversation" })
    ).not.toBeInTheDocument();
  });

  it("offers a new-room primary recovery and workspace sign-in for a missing guest link", () => {
    renderPage();

    expect(
      screen.getByRole("link", { name: "Start new room" })
    ).toHaveAttribute("href", "/");
    expect(
      screen.getByRole("link", { name: "Sign in to a workspace" })
    ).toHaveAttribute("href", "/sign-in");
  });

  it("explains how to recover when a restored guest session has ended", async () => {
    vi.restoreAllMocks();
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockResolvedValue(new Response(
      JSON.stringify({
        error: {
          code: "guest_session_unavailable",
          detail: "This guest communication link is unavailable."
        }
      }),
      { status: 401, headers: { "content-type": "application/json" } }
    )));
    storeGuestSession(guestSession);

    renderPage();

    expect(
      await screen.findByRole("heading", { name: "Guest access has ended" })
    ).toBeVisible();
    expect(
      screen.getByText(
        "This guest session expired or was revoked. Ask the room host for a new link."
      )
    ).toBeVisible();
    expect(window.sessionStorage.getItem("k-comms.guest-session.v1")).toBeNull();
  });

  it("keeps a failed invite retired when the user returns to sign in", async () => {
    const user = userEvent.setup();
    const previewGuestLink = vi.spyOn(GuestApiClient.prototype, "previewGuestLink")
      .mockRejectedValue(new Error("Invite rejected"));
    window.history.replaceState({}, "", "/join#guest=return-secret");
    const first = renderPage();

    await user.click(
      await screen.findByRole("link", { name: "Sign in to a workspace" })
    );
    expect(window.location.pathname).toBe("/sign-in");
    first.unmount();
    window.history.replaceState({}, "", "/join");
    renderPage();

    expect(
      screen.getByRole("heading", { name: "Open a K-Comms guest link" })
    ).toBeVisible();
    expect(previewGuestLink).toHaveBeenCalledTimes(1);
  });
});
