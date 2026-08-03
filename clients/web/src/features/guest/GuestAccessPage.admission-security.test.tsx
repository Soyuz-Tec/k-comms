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
import { SessionProvider } from "../../app/session";
import type {
  Conversation,
  GuestLinkPreview,
  GuestSession,
  Message,
  ReactionEvent,
  Session
} from "../../types";
import {
  GuestAccessPage,
  GuestShell
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

const whiteboardHarness = vi.hoisted(() => ({
  props: null as null | {
    clearRequestId?: number;
    conversationId: string;
    compact: boolean;
    collaborationOptions: {
      userId: string;
      deviceId: string;
    };
  }
}));

vi.mock("../../lib/transportSecurity", () => ({
  isEncryptedUrl: () => false,
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

vi.mock("../whiteboard/CollaborativeWhiteboard", () => ({
  CollaborativeWhiteboard: (props: {
    clearRequestId?: number;
    conversationId: string;
    compact: boolean;
    collaborationOptions: {
      userId: string;
      deviceId: string;
    };
  }) => {
    whiteboardHarness.props = props;
    return <div aria-label="Mock shared canvas">Shared canvas ready</div>;
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
    expect(screen.queryByLabelText("Mock shared canvas")).not.toBeInTheDocument();
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

  it("fills the instant room with canvas and moves room functions into floating controls", async () => {
    const api = new GuestApiClient("", guestSession, vi.fn());

    render(
      <BrowserRouter>
        <GuestShell
          api={api}
          initialSession={guestSession}
          accountActionsAllowed
          mediaActionsAllowed
          onLeave={vi.fn()}
          onConverted={vi.fn()}
          identityLabel="Host"
          whiteboardEnabled
        />
      </BrowserRouter>
    );

    expect(await screen.findByLabelText("Mock shared canvas")).toBeVisible();
    expect(screen.getByLabelText("Shared drawing canvas")).toBeVisible();
    expect(screen.getByLabelText("Room messages")).toBeVisible();
    expect(document.querySelector(".guest-shell-header")).toBeNull();
    expect(document.querySelector(".guest-collaboration-workspace"))
      .toHaveClass("canvas-workspace");
    expect(document.querySelector(".guest-floating-chat")).not.toBeNull();
    expect(screen.getByRole("button", { name: "Move messages" })).toBeVisible();
    expect(whiteboardHarness.props).toMatchObject({
      conversationId: conversation.id,
      compact: true,
      collaborationOptions: {
        userId: guestSession.user.id,
        deviceId: guestSession.device.id
      }
    });

    fireEvent.click(screen.getByRole("button", { name: "Open room menu" }));
    const menu = screen.getByRole("dialog", {
      name: conversation.title ?? "Conversation"
    });
    const messages = within(menu).getByRole("button", { name: "Messages" });
    expect(messages).toHaveAttribute("aria-pressed", "true");
    expect(within(menu).getByRole("button", { name: "Participants" })).toBeVisible();
    expect(within(menu).getByRole("heading", { name: "Calls" })).toBeVisible();
    expect(whiteboardHarness.props?.clearRequestId).toBe(0);
    fireEvent.click(within(menu).getByRole("button", { name: "Clear canvas" }));
    expect(whiteboardHarness.props?.clearRequestId).toBe(1);

    fireEvent.click(screen.getByRole("button", { name: "Open room menu" }));
    const reopenedMenu = screen.getByRole("dialog", {
      name: conversation.title ?? "Conversation"
    });
    const reopenedMessages = within(reopenedMenu).getByRole("button", {
      name: "Messages"
    });

    fireEvent.click(reopenedMessages);
    expect(document.querySelector(".guest-floating-chat")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Open room menu" }));
    fireEvent.click(
      within(screen.getByRole("dialog", {
        name: conversation.title ?? "Conversation"
      }))
        .getByRole("button", { name: "Messages" })
    );
    expect(document.querySelector(".guest-floating-chat")).not.toBeNull();
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
    window.history.replaceState(
      {},
      "",
      `/join#guest=${"a".repeat(43)}`
    );

    renderPage();
    await user.type(
      await screen.findByRole("textbox", { name: "Your display name" }),
      "Taylor"
    );
    await user.click(
      screen.getByRole("button", { name: "Join conversation" })
    );

    expect(await screen.findByRole("heading", { name: "Launch room" })).toBeVisible();
    expect(await screen.findByLabelText("Mock shared canvas")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Open room menu" }));
    expect(
      within(screen.getByRole("dialog", { name: "Launch room" }))
        .getByRole("heading", { name: "Scan to join" })
    ).toBeVisible();
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

    await user.click(screen.getByRole("button", { name: "Open room menu" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Launch room" }))
        .getByRole("button", { name: /Leave room/ })
    );

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
});
