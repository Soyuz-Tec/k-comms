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
  storeSession,
  storeGuestSession
} from "../../api";
import { SessionProvider, useSession } from "../../app/session";
import type {
  Conversation,
  ConversationMembership,
  GuestLinkPreview,
  GuestSession,
  Message,
  ReactionEvent,
  Session
} from "../../types";
import {
  GuestAccessPage,
  GuestShell,
  loadGuestMessageCatchUp
} from "./GuestAccessPage";
import { participantDisambiguator } from "../../lib/participantIdentity";
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

const preview: GuestLinkPreview = {
  room_title: "Launch room",
  expires_at: "2026-07-25T12:00:00Z",
  conversion_enabled: true,
  email_hint: "t***@example.test"
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

  it("scrubs the secret and redeems with a single display-name field", async () => {
    const user = userEvent.setup();
    const previewGuestLink = vi.spyOn(GuestApiClient.prototype, "previewGuestLink")
      .mockResolvedValue(preview);
    const joinGuest = vi.spyOn(GuestApiClient.prototype, "joinGuest")
      .mockResolvedValue(guestSession);
    window.history.replaceState({}, "", "/join#guest=single-use-secret");

    renderPage();

    expect(window.location.hash).toBe("");
    await waitFor(() =>
      expect(previewGuestLink).toHaveBeenCalledWith("single-use-secret")
    );
    const form = await screen.findByRole("button", { name: "Join conversation" })
      .then((button) => button.closest("form"));
    expect(form).not.toBeNull();
    expect(within(form as HTMLFormElement).getAllByRole("textbox")).toHaveLength(1);

    await user.type(screen.getByRole("textbox", { name: "Your display name" }), "Taylor");
    await user.click(screen.getByRole("button", { name: "Join conversation" }));

    await waitFor(() => expect(joinGuest).toHaveBeenCalledWith({
      token: "single-use-secret",
      display_name: "Taylor",
      device: expect.objectContaining({ platform: "web" })
    }));
    expect(await screen.findByRole("heading", { name: "Launch room" })).toBeVisible();
    expect(screen.getByText("Guest", { selector: ".guest-badge" })).toBeVisible();
    expect(screen.getByRole("region", { name: "Room call" })).toBeVisible();
    expect(screen.getByLabelText("Guest call controls")).toBeVisible();
    expect(screen.getByRole("region", { name: "Message history" }))
      .toHaveAttribute("tabindex", "0");
    expect(screen.getByRole("textbox", { name: "Message" })).toHaveFocus();
    await user.click(screen.getByRole("button", { name: "Open mocked room chat" }));
    await waitFor(() =>
      expect(screen.getByRole("textbox", { name: "Message" })).toHaveFocus()
    );
  });

  it("blocks account conversion and media controls on unencrypted non-loopback HTTP", async () => {
    transportHarness.insecureNetworkOrigin = true;
    const user = userEvent.setup();
    const convertAccount = vi.spyOn(
      GuestApiClient.prototype,
      "convertAccount"
    );
    const insecureSession: GuestSession = {
      ...guestSession,
      capabilities: {
        ...guestSession.capabilities,
        self_service_conversion: true
      }
    };
    const api = new GuestApiClient("", insecureSession, vi.fn());

    render(
      <BrowserRouter>
        <GuestShell
          api={api}
          initialSession={insecureSession}
          accountActionsAllowed={false}
          mediaActionsAllowed={false}
          onLeave={vi.fn()}
          onConverted={vi.fn()}
          identityLabel="Host"
        />
      </BrowserRouter>
    );

    expect(
      await screen.findByText(
        "Secure account and media actions are unavailable."
      )
    ).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Save this room" }));
    expect(screen.getByRole("textbox", { name: "Work email" })).toBeDisabled();
    expect(screen.getByRole("textbox", { name: /Display name/ })).toBeDisabled();
    expect(screen.getByLabelText(/^Password/)).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Create account" })
    ).toBeDisabled();

    fireEvent.submit(
      screen
        .getByRole("button", { name: "Create account" })
        .closest("form") as HTMLFormElement
    );
    expect(convertAccount).not.toHaveBeenCalled();
    await waitFor(() =>
      expect(callPanelHarness.props).toMatchObject({
        audioEnabled: false,
        videoEnabled: false
      })
    );
  });

  it("leaves immediately while keepalive revocation is still pending", async () => {
    const user = userEvent.setup();
    let resolveLogout!: () => void;
    const pendingLogout = new Promise<void>((resolve) => {
      resolveLogout = resolve;
    });
    const logout = vi
      .mocked(GuestApiClient.prototype.logout)
      .mockReturnValueOnce(pendingLogout);
    const onLeave = vi.fn();
    const api = new GuestApiClient("", guestSession, vi.fn());
    const view = render(
      <BrowserRouter>
        <GuestShell
          api={api}
          initialSession={guestSession}
          accountActionsAllowed
          mediaActionsAllowed
          onLeave={onLeave}
          onConverted={vi.fn()}
        />
      </BrowserRouter>
    );

    await screen.findByRole("heading", { name: "Launch room" });
    await user.click(screen.getByRole("button", { name: "Leave" }));

    expect(logout).toHaveBeenCalledTimes(1);
    expect(onLeave).toHaveBeenCalledTimes(1);
    view.unmount();
    await act(async () => {
      resolveLogout();
      await pendingLogout;
    });
    expect(onLeave).toHaveBeenCalledTimes(1);
  });

  it("moves mobile room actions into a labelled, dismissible menu", async () => {
    setMobileRoomLayout(true);
    const user = userEvent.setup();
    const onLeave = vi.fn();
    const api = new GuestApiClient("", guestSession, vi.fn());

    render(
      <BrowserRouter>
        <GuestShell
          api={api}
          initialSession={guestSession}
          accountActionsAllowed
          mediaActionsAllowed
          onLeave={onLeave}
          onConverted={vi.fn()}
          identityLabel="Host"
          roomBanner={<section aria-label="Standalone invite">Standalone invite controls</section>}
          roomMenuInvite={(
            <section aria-label="Invite QR">
              <h3>Scan to join</h3>
              <div>Room QR code</div>
            </section>
          )}
        />
      </BrowserRouter>
    );

    await screen.findByRole("heading", { name: "Launch room" });
    const mobilePresence = document.querySelector(".guest-room-heading p");
    expect(mobilePresence).toHaveAttribute("role", "status");
    expect(mobilePresence).toHaveAttribute("aria-live", "polite");
    expect(mobilePresence).toHaveAttribute("aria-atomic", "true");
    expect(document.querySelector(".guest-connection")).not.toHaveAttribute(
      "role",
      "status"
    );
    const trigger = screen.getByRole("button", { name: "Open room menu" });
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByRole("region", { name: "Standalone invite" }))
      .not.toBeInTheDocument();
    expect(screen.queryByRole("region", { name: "Invite QR" }))
      .not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Leave" })).not.toBeInTheDocument();

    await user.click(trigger);
    const menu = screen.getByRole("dialog", { name: "Room menu" });
    expect(trigger).toHaveAttribute("aria-expanded", "true");
    expect(within(menu).getByRole("region", { name: "Invite QR" })).toBeVisible();
    expect(within(menu).getByRole("heading", { name: "Scan to join" })).toBeVisible();
    expect(within(menu).getByRole("button", { name: /Save this room/ })).toBeVisible();
    expect(within(menu).getByRole("link", { name: /Sign in to a workspace/ })).toBeVisible();
    expect(within(menu).getByRole("button", { name: /Leave room/ })).toHaveTextContent(
      "Leaving clears this guest host session."
    );
    await waitFor(() =>
      expect(within(menu).getByRole("button", { name: "Close" })).toHaveFocus()
    );

    await user.click(within(menu).getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("dialog", { name: "Room menu" })).not.toBeInTheDocument();
    await waitFor(() => expect(trigger).toHaveFocus());

    await user.click(trigger);
    expect(screen.getByRole("dialog", { name: "Room menu" })).toBeVisible();
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog", { name: "Room menu" })).not.toBeInTheDocument();
    await waitFor(() => expect(trigger).toHaveFocus());

    await user.click(trigger);
    await user.click(
      within(screen.getByRole("dialog", { name: "Room menu" }))
        .getByRole("button", { name: /Save this room/ })
    );
    await waitFor(() =>
      expect(screen.getByRole("textbox", { name: "Work email" })).toHaveFocus()
    );
    await user.click(screen.getByRole("button", { name: "Not now" }));
    await waitFor(() => expect(trigger).toHaveFocus());

    await user.click(trigger);
    await user.click(
      within(screen.getByRole("dialog", { name: "Room menu" }))
        .getByRole("button", { name: /Leave room/ })
    );
    expect(GuestApiClient.prototype.logout).toHaveBeenCalled();
    expect(onLeave).toHaveBeenCalledTimes(1);
  });

  it("keeps credential and media controls blocked when a LAN release is opened through loopback", async () => {
    const status = vi.mocked(ApiClient.prototype.status);
    status.mockResolvedValue({
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
        secure_account_actions: false,
        secure_media_actions: false,
        webhooks: true
      }
    });
    const loopbackGuestSession: GuestSession = {
      ...guestSession,
      capabilities: {
        ...guestSession.capabilities,
        self_service_conversion: true
      }
    };
    storeGuestSession(loopbackGuestSession);
    const user = userEvent.setup();

    renderPage();

    expect(await screen.findByRole("heading", { name: "Launch room" })).toBeVisible();
    await waitFor(() => expect(status).toHaveBeenCalled());
    expect(
      screen.getByText("Secure account and media actions are unavailable.")
    ).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Keep this conversation" }));
    expect(screen.getByRole("textbox", { name: "Work email" })).toBeDisabled();
    expect(screen.getByLabelText(/^Password/)).toBeDisabled();
    await waitFor(() =>
      expect(callPanelHarness.props).toMatchObject({
        audioEnabled: false,
        videoEnabled: false
      })
    );
  });

  it("keeps legacy guest links usable when instant rooms are disabled", async () => {
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockRejectedValue(
      new ApiError(
        503,
        "instant_rooms_unavailable",
        "Instant communication rooms are unavailable"
      )
    );
    const previewGuestLink = vi
      .spyOn(GuestApiClient.prototype, "previewGuestLink")
      .mockResolvedValue(preview);
    window.history.replaceState({}, "", "/join#guest=legacy-link-secret");

    renderPage();

    expect(
      await screen.findByRole("button", { name: "Join conversation" })
    ).toBeVisible();
    expect(previewGuestLink).toHaveBeenCalledWith("legacy-link-secret");
    expect(
      screen.queryByText(/Instant communication rooms are unavailable/i)
    ).not.toBeInTheDocument();
  });

  it("retries a transient preview with the scrubbed token still in memory", async () => {
    const user = userEvent.setup();
    const previewGuestLink = vi
      .spyOn(GuestApiClient.prototype, "previewGuestLink")
      .mockRejectedValueOnce(
        new ApiError(503, "service_unavailable", "Temporarily unavailable")
      )
      .mockResolvedValueOnce(preview);
    window.history.replaceState({}, "", "/join#guest=retry-preview-secret");

    renderPage();

    expect(window.location.hash).toBe("");
    expect(
      await screen.findByText(/K-Comms is temporarily unavailable/i)
    ).toBeVisible();
    await user.click(
      screen.getByRole("button", { name: "Retry invite link" })
    );

    expect(
      await screen.findByRole("button", { name: "Join conversation" })
    ).toBeVisible();
    expect(previewGuestLink).toHaveBeenCalledTimes(2);
    expect(previewGuestLink).toHaveBeenNthCalledWith(
      1,
      "retry-preview-secret"
    );
    expect(previewGuestLink).toHaveBeenNthCalledWith(
      2,
      "retry-preview-secret"
    );
    expect(window.location.hash).toBe("");
  });

  it("joins an instant room once with the signed-in identity and never also creates a guest", async () => {
    const user = userEvent.setup();
    const token = "A".repeat(43);
    const accountSession: Session = {
      ...guestSession,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...guestSession.user,
        display_name: "Taylor Member",
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    storeSession(accountSession);
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockResolvedValue({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    const joinInstantRoom = vi
      .spyOn(ApiClient.prototype, "joinInstantRoom")
      .mockResolvedValue({
        room: {
          id: "room-1",
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
        conversation
      });
    const guestJoin = vi.spyOn(GuestApiClient.prototype, "joinInstantRoom");
    window.history.replaceState({}, "", `/join#guest=${token}`);

    renderPage();

    await user.click(
      await screen.findByRole("button", { name: "Join as Taylor Member" })
    );

    await waitFor(() => expect(joinInstantRoom).toHaveBeenCalledWith(
      { token },
      expect.stringMatching(/^[A-Za-z0-9_-]{43}$/)
    ));
    expect(guestJoin).not.toHaveBeenCalled();
    expect(window.location.pathname).toBe("/app/");
    expect(window.location.search).toBe("?conversation=conversation-1");
    expect(
      window.sessionStorage.getItem("k-comms.member-instant-room.v1")
    ).toContain(conversation.id);
  });

  it("retries an ambiguous signed-in join with the same account idempotency key", async () => {
    const user = userEvent.setup();
    const token = "N".repeat(43);
    const accountSession: Session = {
      ...guestSession,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...guestSession.user,
        display_name: "Taylor Member",
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    storeSession(accountSession);
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockResolvedValue({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    const joinInstantRoom = vi
      .spyOn(ApiClient.prototype, "joinInstantRoom")
      .mockRejectedValueOnce(new TypeError("response was lost"))
      .mockResolvedValueOnce({
        room: {
          id: "room-network-replay",
          conversation_id: conversation.id,
          owner_user_id: accountSession.user.id,
          owner_kind: "registered",
          status: "active",
          participant_limit: 25,
          idle_since: null,
          expires_at: null,
          inserted_at: "2026-07-24T12:00:00Z",
          updated_at: "2026-07-24T12:00:00Z"
        },
        conversation
      });
    const guestJoin = vi.spyOn(
      GuestApiClient.prototype,
      "joinInstantRoom"
    );
    window.history.replaceState({}, "", `/join#guest=${token}`);

    renderPage();
    await user.click(
      await screen.findByRole("button", { name: "Join as Taylor Member" })
    );

    await waitFor(
      () => expect(joinInstantRoom).toHaveBeenCalledTimes(2),
      { timeout: 2_000 }
    );
    expect(joinInstantRoom.mock.calls[1]![1]).toBe(
      joinInstantRoom.mock.calls[0]![1]
    );
    expect(guestJoin).not.toHaveBeenCalled();
    expect(
      screen.queryByRole("textbox", { name: "Your display name" })
    ).not.toBeInTheDocument();
    await waitFor(() => expect(window.location.pathname).toBe("/app/"));
  });

  it("rotates an expired signed-in join replay once and completes admission", async () => {
    const user = userEvent.setup();
    const accountSession: Session = {
      ...guestSession,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...guestSession.user,
        display_name: "Taylor Member",
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    storeSession(accountSession);
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockResolvedValue({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    const joinInstantRoom = vi
      .spyOn(ApiClient.prototype, "joinInstantRoom")
      .mockRejectedValueOnce(
        new ApiError(
          409,
          "idempotency_replay_expired",
          "The replay window ended"
        )
      )
      .mockResolvedValueOnce({
        room: {
          id: "room-1",
          conversation_id: conversation.id,
          owner_user_id: accountSession.user.id,
          owner_kind: "registered",
          status: "active",
          participant_limit: 25,
          idle_since: null,
          expires_at: null,
          inserted_at: "2026-07-24T12:00:00Z",
          updated_at: "2026-07-24T12:00:00Z"
        },
        conversation
      });
    window.history.replaceState({}, "", "/join#guest=instant-secret");

    renderPage();
    await user.click(
      await screen.findByRole("button", { name: "Join as Taylor Member" })
    );

    await waitFor(() => expect(joinInstantRoom).toHaveBeenCalledTimes(2));
    expect(joinInstantRoom.mock.calls[1]![1]).not.toBe(
      joinInstantRoom.mock.calls[0]![1]
    );
    expect(window.location.pathname).toBe("/app/");
  });

  it("rotates an expired guest join replay once and completes admission", async () => {
    const user = userEvent.setup();
    const instantSession: GuestSession = {
      ...guestSession,
      instant_room: {
        id: "room-guest",
        conversation_id: conversation.id,
        owner_user_id: guestSession.user.id,
        owner_kind: "guest",
        status: "active",
        participant_limit: 25,
        idle_since: null,
        expires_at: null,
        inserted_at: "2026-07-24T12:00:00Z",
        updated_at: "2026-07-24T12:00:00Z"
      }
    };
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockResolvedValue({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    const joinInstantRoom = vi
      .spyOn(GuestApiClient.prototype, "joinInstantRoom")
      .mockRejectedValueOnce(
        new ApiError(
          409,
          "idempotency_replay_expired",
          "The replay window ended"
        )
      )
      .mockResolvedValueOnce(instantSession);
    window.history.replaceState({}, "", "/join#guest=instant-secret");

    renderPage();
    await user.type(
      await screen.findByRole("textbox", { name: "Your display name" }),
      "Taylor"
    );
    await user.click(
      screen.getByRole("button", { name: "Join conversation" })
    );

    expect(await screen.findByRole("heading", { name: "Launch room" })).toBeVisible();
    expect(joinInstantRoom).toHaveBeenCalledTimes(2);
    expect(joinInstantRoom.mock.calls[1]![1]).not.toBe(
      joinInstantRoom.mock.calls[0]![1]
    );
  });

  it("does not rotate a guest join key for rate limiting", async () => {
    const user = userEvent.setup();
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockResolvedValue({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    const joinInstantRoom = vi
      .spyOn(GuestApiClient.prototype, "joinInstantRoom")
      .mockRejectedValue(
        new ApiError(429, "rate_limited", "Slow down", undefined, 12)
      );
    window.history.replaceState({}, "", "/join#guest=instant-secret");

    renderPage();
    await user.type(
      await screen.findByRole("textbox", { name: "Your display name" }),
      "Taylor"
    );
    await user.click(
      screen.getByRole("button", { name: "Join conversation" })
    );

    expect(
      await screen.findByText("Too many attempts. Try again in 12 seconds.")
    ).toBeVisible();
    expect(
      screen.getByRole("button", { name: /Try again in \d+s/ })
    ).toBeDisabled();
    expect(joinInstantRoom).toHaveBeenCalledTimes(1);
  });

  it("uses a cross-workspace guest fallback without replacing the signed-in account", async () => {
    const user = userEvent.setup();
    const accountSession: Session = {
      ...guestSession,
      access_token: "member-access",
      refresh_token: "member-refresh",
      tenant: {
        id: "tenant-private",
        name: "Private workspace",
        slug: "private-workspace",
        status: "active"
      },
      user: {
        ...guestSession.user,
        tenant_id: "tenant-private",
        display_name: "Taylor Member",
        account_type: "human",
        email: "taylor@example.test"
      }
    };
    const fallbackSession: GuestSession = {
      ...guestSession,
      capabilities: {
        ...guestSession.capabilities,
        self_service_conversion: true
      },
      instant_room: {
        id: "room-public",
        conversation_id: conversation.id,
        owner_user_id: "guest-1",
        owner_kind: "guest",
        status: "active",
        participant_limit: 25,
        idle_since: null,
        expires_at: null,
        inserted_at: "2026-07-24T12:00:00Z",
        updated_at: "2026-07-24T12:00:00Z"
      }
    };
    storeSession(accountSession);
    vi.spyOn(ApiClient.prototype, "previewInstantRoom").mockResolvedValue({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    const joinInstantRoom = vi
      .spyOn(ApiClient.prototype, "joinInstantRoom")
      .mockResolvedValue({
        room: fallbackSession.instant_room!,
        conversation,
        guest_session: fallbackSession
      });
    const guestJoin = vi.spyOn(GuestApiClient.prototype, "joinInstantRoom");
    window.history.replaceState({}, "", "/join#guest=instant-secret");

    renderPage();

    await user.click(
      await screen.findByRole("button", { name: "Join as Taylor Member" })
    );

    await waitFor(() => expect(joinInstantRoom).toHaveBeenCalledTimes(1));
    expect(await screen.findByRole("heading", { name: "Launch room" })).toBeVisible();
    expect(guestJoin).not.toHaveBeenCalled();
    expect(
      screen.queryByRole("button", { name: "Keep this conversation" })
    ).not.toBeInTheDocument();
    expect(
      window.sessionStorage.getItem("k-comms.session.v1")
    ).toContain("member-access");
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
    ).toContain("guest-access");

    await user.click(screen.getByRole("button", { name: "Leave" }));

    await waitFor(() => expect(window.location.pathname).toBe("/app/"));
    expect(
      window.sessionStorage.getItem("k-comms.session.v1")
    ).toContain("member-access");
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
    ).toBeNull();
  });

  it("reads the token through React StrictMode initialization replay before scrubbing", async () => {
    const previewGuestLink = vi.spyOn(GuestApiClient.prototype, "previewGuestLink")
      .mockResolvedValue(preview);
    window.history.replaceState({}, "", "/join#guest=strict-mode-secret");

    renderPage(true);

    expect(window.location.hash).toBe("");
    expect(
      await screen.findByRole("button", { name: "Join conversation" })
    ).toBeVisible();
    expect(previewGuestLink).toHaveBeenCalledWith("strict-mode-secret");
  });

  it("does not reuse a prior token on a later fragmentless mount", async () => {
    const previewGuestLink = vi.spyOn(GuestApiClient.prototype, "previewGuestLink")
      .mockResolvedValue(preview);
    window.history.replaceState({}, "", "/join#guest=prior-secret");

    const first = renderPage();

    expect(
      await screen.findByRole("button", { name: "Join conversation" })
    ).toBeVisible();
    expect(window.location.hash).toBe("");
    first.unmount();
    window.history.replaceState({}, "", "/join");
    renderPage();

    expect(
      screen.getByRole("heading", { name: "Open a K-Comms guest link" })
    ).toBeVisible();
    expect(previewGuestLink).toHaveBeenCalledTimes(1);
  });

  it("uses a newly opened invite instead of a previously stored guest room", async () => {
    storeGuestSession(guestSession);
    const previewGuestLink = vi.spyOn(GuestApiClient.prototype, "previewGuestLink")
      .mockResolvedValue(preview);
    window.history.replaceState({}, "", "/join#guest=second-room-secret");

    renderPage();

    expect(window.location.hash).toBe("");
    await waitFor(() =>
      expect(previewGuestLink).toHaveBeenCalledWith("second-room-secret")
    );
    expect(
      await screen.findByRole("button", { name: "Join conversation" })
    ).toBeVisible();
    expect(screen.queryByLabelText("Guest call controls")).not.toBeInTheDocument();
    expect(window.sessionStorage.getItem("k-comms.guest-session.v1")).toBeNull();
  });

  it("blocks the composer and retries when initial conversation hydration fails", async () => {
    const user = userEvent.setup();
    storeGuestSession(guestSession);
    const conversationLookup = vi
      .spyOn(GuestApiClient.prototype, "conversation")
      .mockRejectedValueOnce(
        new ApiError(503, "service_unavailable", "History is unavailable")
      )
      .mockResolvedValueOnce(conversation);

    renderPage();

    expect(
      await screen.findByRole("heading", {
        name: "Could not load this conversation"
      })
    ).toBeVisible();
    const composer = screen.getByRole("textbox", { name: "Message" });
    expect(composer).toHaveAttribute("readonly");
    expect(composer).toHaveAttribute("aria-disabled", "true");
    expect(
      screen.queryByRole("heading", { name: "No messages yet" })
    ).not.toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "Retry conversation" })
    );

    expect(
      await screen.findByRole("heading", { name: "No messages yet" })
    ).toBeVisible();
    expect(composer).not.toHaveAttribute("readonly");
    expect(conversationLookup).toHaveBeenCalledTimes(2);
  });

  it("ends a stale guest room when socket authorization is forbidden", async () => {
    storeGuestSession(guestSession);
    vi.spyOn(GuestApiClient.prototype, "socketTicket").mockRejectedValue(
      new ApiError(403, "guest_access_revoked", "Access revoked")
    );

    renderPage();

    expect(
      await screen.findByRole("heading", { name: "Guest access has ended" })
    ).toBeVisible();
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
    ).toBeNull();
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
      screen.getByRole("textbox", { name: "Work email" }),
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
      await screen.findByRole("button", { name: "Keep this conversation" })
    );
    await user.type(
      screen.getByRole("textbox", { name: "Work email" }),
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
    expect(screen.getByText("Member", { selector: ".guest-badge" })).toBeVisible();
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
      await screen.findByRole("button", { name: "Keep this conversation" })
    );
    await user.type(
      screen.getByRole("textbox", { name: "Work email" }),
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

describe("loadGuestMessageCatchUp", () => {
  it("loads more than 700 messages through bounded forward pages", async () => {
    const allMessages = Array.from({ length: 750 }, (_, index) => message(index + 1));
    const capturedLabels: string[] = [];
    const messages = vi.fn(async (afterSequence: number, limit: number) => {
      const data = allMessages.slice(afterSequence, afterSequence + limit);
      const nextAfterSequence = data.at(-1)?.conversation_sequence ?? null;
      return {
        data,
        included: {
          sender_labels: [
            {
              id: `sender-page-${afterSequence}`,
              display_name: `Sender ${afterSequence}`,
              redacted: false
            }
          ]
        },
        page: {
          has_more: afterSequence + data.length < allMessages.length,
          next_after_sequence: nextAfterSequence,
          reset_required: false
        }
      };
    });

    await expect(
      loadGuestMessageCatchUp(
        { messages } as unknown as Pick<GuestApiClient, "messages">,
        0,
        (labels) => capturedLabels.push(...labels.map(({ id }) => id))
      )
    ).resolves.toHaveLength(750);
    expect(messages.mock.calls.map(([afterSequence]) => afterSequence)).toEqual([
      0,
      200,
      400,
      600
    ]);
    expect(capturedLabels).toEqual([
      "sender-page-0",
      "sender-page-200",
      "sender-page-400",
      "sender-page-600"
    ]);
  });
});
