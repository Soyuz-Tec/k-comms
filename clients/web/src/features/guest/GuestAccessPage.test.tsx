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
  GuestShell,
  loadGuestMessageCatchUp
} from "./GuestAccessPage";

const realtimeHarness = vi.hoisted(() => ({
  callbacks: null as null | {
    onStatus: (status: string) => void;
    onMessages: (messages: Message[]) => void;
    onReactionAdded: (event: ReactionEvent) => void;
    onReactionRemoved: (event: ReactionEvent) => void;
  },
  tickets: [] as string[],
  disconnects: 0
}));

vi.mock("../calls/CallPanel", () => ({
  CallPanel: () => <div aria-label="Guest call controls">Audio and video controls</div>
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

describe("GuestAccessPage", () => {
  beforeEach(() => {
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/join");
    realtimeHarness.callbacks = null;
    realtimeHarness.tickets = [];
    realtimeHarness.disconnects = 0;
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "visible"
    });
    vi.restoreAllMocks();
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
    expect(screen.getByLabelText("Guest call controls")).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Message" })).toHaveFocus();
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
      screen.getByRole("button", { name: "Retry secure link" })
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
    expect(window.location.pathname).toBe("/app");
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
    await waitFor(() => expect(window.location.pathname).toBe("/app"));
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
    expect(window.location.pathname).toBe("/app");
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
      screen.queryByRole("button", { name: "Create account" })
    ).not.toBeInTheDocument();
    expect(
      window.sessionStorage.getItem("k-comms.session.v1")
    ).toContain("member-access");
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
    ).toContain("guest-access");

    await user.click(screen.getByRole("button", { name: "Leave" }));

    await waitFor(() => expect(window.location.pathname).toBe("/app"));
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
      screen.queryByRole("heading", { name: "Start the conversation" })
    ).not.toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "Retry conversation" })
    );

    expect(
      await screen.findByRole("heading", { name: "Start the conversation" })
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

    const accountToggle = await screen.findByRole("button", { name: "Create account" });
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
    await waitFor(() => expect(window.location.pathname).toBe("/app"));
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
      <GuestShell
        api={api}
        initialSession={selfServiceSession}
        onLeave={vi.fn()}
        onConverted={onConverted}
        roomBanner={<div>Share controls remain mounted</div>}
      />
    );

    expect(await screen.findByText("Message 1")).toBeVisible();
    await waitFor(() =>
      expect(realtimeHarness.tickets).toEqual(["socket-ticket"])
    );
    await user.click(screen.getByRole("button", { name: "Create account" }));
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
      await screen.findByRole("button", { name: "Create account" })
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
        screen.queryByRole("button", { name: "Create account" })
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
      await screen.findByRole("button", { name: "Create account" })
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

    await waitFor(() => expect(window.location.pathname).toBe("/app"));
    expect(window.location.search).toBe(
      `?conversation=${encodeURIComponent(conversation.id)}`
    );
    expect(memberConversation).toHaveBeenCalledWith(conversation.id);
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
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
      screen.queryByRole("button", { name: "Create account" })
    ).not.toBeInTheDocument();
  });

  it("offers a clear K-Comms sign-in action for a missing guest link", () => {
    renderPage();

    expect(
      screen.getByRole("link", { name: "Return to K-Comms sign in" })
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
      await screen.findByRole("link", { name: "Return to K-Comms sign in" })
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
    act(() => resolveSend?.(message(1, guestSession.user.id)));
    await waitFor(() => expect(composer).not.toHaveAttribute("readonly"));
    expect(composer).toHaveFocus();
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
    const messages = vi.fn(async (afterSequence: number, limit: number) => {
      const data = allMessages.slice(afterSequence, afterSequence + limit);
      const nextAfterSequence = data.at(-1)?.conversation_sequence ?? null;
      return {
        data,
        page: {
          has_more: afterSequence + data.length < allMessages.length,
          next_after_sequence: nextAfterSequence,
          reset_required: false
        }
      };
    });

    await expect(
      loadGuestMessageCatchUp({ messages } as unknown as Pick<GuestApiClient, "messages">, 0)
    ).resolves.toHaveLength(750);
    expect(messages.mock.calls.map(([afterSequence]) => afterSequence)).toEqual([
      0,
      200,
      400,
      600
    ]);
  });
});
