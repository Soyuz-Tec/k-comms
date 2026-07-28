import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode, useState } from "react";
import { BrowserRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiClient,
  ApiError,
  storeGuestSession,
  storeSession
} from "../../api";
import { SessionProvider, useSession } from "../../app/session";
import type {
  Conversation,
  GuestSession,
  InstantRoom,
  InstantRoomResult,
  Session
} from "../../types";
import { InstantRoomPage } from "./InstantRoomPage";
import { storeMemberInstantRoomContinuity } from "./memberContinuity";

const uiHarness = vi.hoisted(() => ({
  qrValue: "",
  shellRenders: 0,
  roomApis: [] as unknown[],
  delegatedTicket: ""
}));

vi.mock("../guest/QrCode", () => ({
  QrCode: ({ value }: { value: string }) => {
    uiHarness.qrValue = value;
    return <div aria-label="Local QR">{value}</div>;
  }
}));

vi.mock("../guest/GuestAccessPage", () => ({
  GuestShell: ({
    api,
    initialSession,
    onConverted,
    onLeave,
    roomBanner,
    roomMenuInvite
  }: {
    api: { socketTicket: () => Promise<{ ticket: string; expires_in: number }> };
    initialSession: GuestSession;
    onConverted: (session: GuestSession, conversation: Conversation) => void;
    onLeave: () => void;
    roomBanner?: React.ReactNode | ((participantCount: number) => React.ReactNode);
    roomMenuInvite?: React.ReactNode | ((participantCount: number) => React.ReactNode);
  }) => {
    const [roomMenuOpen, setRoomMenuOpen] = useState(false);
    uiHarness.shellRenders += 1;
    uiHarness.roomApis.push(api);
    return (
      <main>
        <h1>Live room</h1>
        <span>{initialSession.user.account_type}</span>
        {initialSession.capabilities.self_service_conversion === true && (
          <span>Account creation available</span>
        )}
        <button
          type="button"
          onClick={() => onConverted(
            {
              ...initialSession,
              access_token: "member-access",
              refresh_token: "member-refresh",
              user: {
                ...initialSession.user,
                account_type: "human",
                email: "host@example.test"
              }
            },
            initialSession.conversation
          )}
        >
          Simulate account upgrade
        </button>
        <button
          type="button"
          onClick={() => void api.socketTicket().then(({ ticket }) => {
            uiHarness.delegatedTicket = ticket;
          })}
        >
          Request current socket ticket
        </button>
        <button type="button" onClick={onLeave}>
          Leave room
        </button>
        <button
          type="button"
          aria-expanded={roomMenuOpen}
          onClick={() => setRoomMenuOpen(true)}
        >
          Open room menu
        </button>
        {typeof roomBanner === "function" ? roomBanner(1) : roomBanner}
        {roomMenuOpen && (
          <aside role="dialog" aria-label="Room menu">
            <button type="button" onClick={() => setRoomMenuOpen(false)}>
              Close
            </button>
            {typeof roomMenuInvite === "function"
              ? roomMenuInvite(1)
              : roomMenuInvite}
          </aside>
        )}
      </main>
    );
  }
}));

const conversation: Conversation = {
  id: "conversation-instant",
  tenant_id: "tenant-public",
  kind: "group",
  title: "Instant room",
  counterpart_user_id: null,
  counterpart_display_name: null,
  visibility: "private",
  latest_sequence: 0,
  inserted_at: "2026-07-24T12:00:00Z",
  updated_at: "2026-07-24T12:00:00Z"
};

const room: InstantRoom = {
  id: "room-instant",
  conversation_id: conversation.id,
  owner_user_id: "guest-host",
  status: "active",
  owner_kind: "guest",
  participant_limit: 25,
  idle_since: null,
  expires_at: null,
  inserted_at: "2026-07-24T12:00:00Z",
  updated_at: "2026-07-24T12:00:00Z"
};

const guestSession: GuestSession = {
  access_token: "guest-access",
  refresh_token: "guest-refresh",
  token_type: "Bearer",
  expires_in: 900,
  tenant: {
    id: "tenant-public",
    name: "Public rooms",
    slug: "public-rooms",
    status: "active"
  },
  user: {
    id: "guest-host",
    tenant_id: "tenant-public",
    display_name: "Guest host",
    account_type: "guest",
    role: "member",
    status: "active"
  },
  device: {
    id: "device-browser",
    user_id: "guest-host",
    name: "Browser",
    platform: "web"
  },
  conversation,
  capabilities: {
    allow_audio_calls: true,
    allow_video_calls: true,
    conversion_enabled: true,
    self_service_conversion: true
  }
};

const shareUrl =
  `https://comms.example.test/join#guest=${"S".repeat(43)}`;
const result: InstantRoomResult = {
  room,
  conversation,
  share_url: shareUrl,
  guest_session: guestSession
};

function renderPage(strict = false) {
  const page = (
    <SessionProvider>
      <BrowserRouter>
        <InstantRoomPage />
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

async function startRoom(
  user: ReturnType<typeof userEvent.setup>,
  options: { displayName?: string; title?: string } = {
    displayName: "Taylor Host"
  }
) {
  if (options.displayName !== undefined) {
    const displayName = screen.getByRole("textbox", {
      name: "Your display name"
    });
    await user.clear(displayName);
    await user.type(displayName, options.displayName);
  }
  if (options.title !== undefined) {
    await user.type(
      screen.getByRole("textbox", { name: /Room name/ }),
      options.title
    );
  }
  await user.click(
    screen.getByRole("button", { name: "Start instant room" })
  );
}

async function openInviteDetails(
  user: ReturnType<typeof userEvent.setup>
) {
  const invite = screen.getByRole("button", { name: "Invite people" });
  expect(invite).toHaveAttribute("aria-expanded", "false");
  expect(invite).toHaveAttribute("aria-controls", "instant-room-invite-dialog");
  await user.click(invite);
  expect(
    await screen.findByRole("dialog", { name: "Invite someone" })
  ).toBeVisible();
  expect(invite).toHaveAttribute("aria-expanded", "true");
}

describe("InstantRoomPage", () => {
  beforeEach(() => {
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/");
    uiHarness.qrValue = "";
    uiHarness.shellRenders = 0;
    uiHarness.roomApis = [];
    uiHarness.delegatedTicket = "";
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
  });

  it("guides an empty anonymous start with associated validation and focus recovery", async () => {
    const user = userEvent.setup();
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue(result);

    renderPage();
    const displayName = screen.getByRole("textbox", {
      name: "Your display name"
    });
    const roomName = screen.getByRole("textbox", { name: /Room name/ });
    const start = screen.getByRole("button", { name: "Start instant room" });

    expect(displayName).toBeRequired();
    expect(roomName).not.toBeRequired();
    expect(displayName).not.toHaveFocus();
    expect(displayName).toHaveAccessibleDescription(
      "Visible to everyone in the room."
    );
    expect(roomName).toHaveAccessibleDescription(
      "Defaults to “Instant room”."
    );
    expect(screen.getByText("Required")).toBeVisible();
    expect(screen.getByText("Optional")).toBeVisible();
    expect(screen.getByText("Defaults to “Instant room”.")).toBeVisible();
    expect(start).toBeEnabled();

    await user.click(start);

    const validation = screen.getByRole("alert");
    expect(validation).toHaveTextContent(
      "Enter your display name to continue."
    );
    expect(displayName).toHaveFocus();
    expect(displayName).toHaveAttribute("aria-invalid", "true");
    expect(displayName).toHaveAttribute(
      "aria-describedby",
      "instant-room-display-name-help instant-room-display-name-error"
    );
    expect(create).not.toHaveBeenCalled();

    await user.type(displayName, "   ");
    await user.click(start);
    expect(create).not.toHaveBeenCalled();
    expect(displayName).toHaveFocus();

    await user.type(displayName, "Taylor Host");
    expect(screen.queryByText("Enter your display name to continue."))
      .not.toBeInTheDocument();
    expect(displayName).toHaveAttribute("aria-invalid", "false");
    await user.click(start);

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    expect(create.mock.calls[0]?.[0]).toEqual(expect.objectContaining({
      display_name: "Taylor Host"
    }));
  });

  it("creates once under StrictMode, enters the room and shares the exact server URL", async () => {
    const user = userEvent.setup();
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue(result);

    renderPage(true);
    expect(
      screen.getByRole("heading", { name: "Start an instant room" })
    ).toBeVisible();
    expect(create).not.toHaveBeenCalled();
    await startRoom(user, {
      displayName: "Taylor Host",
      title: "Daily check-in"
    });

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    const [input, key] = create.mock.calls[0]!;
    expect(input).toEqual(expect.objectContaining({
      display_name: "Taylor Host",
      title: "Daily check-in",
      device: expect.objectContaining({ platform: "web" })
    }));
    expect(key).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(screen.getByRole("region", { name: "Invite people" })).toBeVisible();
    expect(screen.queryByLabelText("Secure room link")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Local QR")).not.toBeInTheDocument();
    await openInviteDetails(user);
    expect(screen.getByLabelText("Secure room link")).not.toHaveValue(shareUrl);
    expect(
      within(screen.getByRole("dialog", { name: "Invite someone" }))
        .getByText(/available for 1 hour after everyone leaves/i)
    ).toBeVisible();
    expect(
      screen.getByRole("heading", { name: "Invite someone" })
    ).toHaveFocus();
    await user.click(screen.getByRole("button", { name: "Show QR code" }));
    expect(screen.getByLabelText("Local QR")).toHaveTextContent(shareUrl);
    expect(uiHarness.qrValue).toBe(shareUrl);
    await user.click(screen.getByRole("button", { name: "Reveal" }));
    expect(screen.getByLabelText("Secure room link")).toHaveValue(shareUrl);
    await user.click(screen.getByRole("button", { name: "Hide invite details" }));
    expect(screen.getByRole("region", { name: "Invite people" })).toBeVisible();
    expect(
      screen.queryByRole("heading", { name: "Invite someone" })
    ).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Secure room link")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Local QR")).not.toBeInTheDocument();
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: "Invite people" })
      ).toHaveFocus()
    );
    await user.click(screen.getByRole("button", { name: "Invite people" }));
    expect(
      screen.getByRole("heading", { name: "Invite someone" })
    ).toBeVisible();

    const stored = window.sessionStorage.getItem("k-comms.guest-session.v1") || "";
    expect(stored).toContain("guest-access");
    expect(window.localStorage.getItem("k-comms.guest-session.v1")).toBeNull();
  });

  it("renders the invite QR immediately inside the room menu only after it opens", async () => {
    const user = userEvent.setup();
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);

    renderPage();
    await startRoom(user);
    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(screen.queryByLabelText("Local QR")).not.toBeInTheDocument();

    const menuTrigger = screen.getByRole("button", { name: "Open room menu" });
    expect(menuTrigger).toHaveAttribute("aria-expanded", "false");
    await user.click(menuTrigger);

    const menu = screen.getByRole("dialog", { name: "Room menu" });
    expect(menuTrigger).toHaveAttribute("aria-expanded", "true");
    expect(within(menu).getByRole("heading", { name: "Scan to join" })).toBeVisible();
    expect(within(menu).getByLabelText("Local QR")).toHaveTextContent(shareUrl);
    expect(within(menu).getByLabelText("Secure room link")).not.toHaveValue(shareUrl);
    expect(within(menu).getByRole("button", { name: "Copy invite link" })).toBeVisible();
    expect(within(menu).getByRole("button", { name: "Share invite link" })).toBeVisible();
    expect(uiHarness.qrValue).toBe(shareUrl);

    await user.click(within(menu).getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("dialog", { name: "Room menu" })).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Local QR")).not.toBeInTheDocument();
  });

  it("reveals a manual menu link when sharing falls back to a rejected clipboard", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockRejectedValue(new Error("clipboard denied"));
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });
    Object.defineProperty(navigator, "share", {
      configurable: true,
      value: undefined
    });
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);

    renderPage();
    await startRoom(user);
    await user.click(
      await screen.findByRole("button", { name: "Open room menu" })
    );

    const menu = screen.getByRole("dialog", { name: "Room menu" });
    const link = within(menu).getByLabelText("Secure room link");
    expect(link).not.toHaveValue(shareUrl);
    await user.click(
      within(menu).getByRole("button", { name: "Share invite link" })
    );

    await waitFor(() => expect(writeText).toHaveBeenCalledWith(shareUrl));
    expect(link).toHaveValue(shareUrl);
    expect(
      within(menu).getByText(
        "Copy failed. The full link is visible so you can copy it manually."
      )
    ).toHaveAttribute("role", "status");
  });

  it("keeps the progress control focused and guarded while creation is pending", async () => {
    const user = userEvent.setup();
    let finishCreation!: (value: InstantRoomResult) => void;
    const pendingCreation = new Promise<InstantRoomResult>((resolve) => {
      finishCreation = resolve;
    });
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockReturnValue(pendingCreation);

    renderPage();
    const displayName = screen.getByRole("textbox", {
      name: "Your display name"
    });
    await user.type(displayName, "Taylor Host");
    await user.click(
      screen.getByRole("button", { name: "Start instant room" })
    );

    const progress = screen.getByRole("button", { name: "Opening room…" });
    expect(progress).toHaveFocus();
    expect(progress).toHaveAttribute("aria-disabled", "true");
    expect(displayName).toBeDisabled();
    expect(
      screen.getByText("Opening your room. Please wait.")
    ).toBeInTheDocument();

    await user.click(progress);
    expect(create).toHaveBeenCalledTimes(1);
    expect(progress).toHaveFocus();

    await act(async () => {
      finishCreation(result);
      await pendingCreation;
    });
    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
  });

  it("reports a denied secure policy without mislabeling the browser address as HTTP", async () => {
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
        secure_account_actions: false,
        secure_media_actions: false,
        webhooks: true
      }
    });

    renderPage();

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Text-only mode is active."
    );
    expect(screen.getByRole("alert")).toHaveTextContent(
      "K-Comms could not verify a trusted HTTPS path"
    );
    expect(
      screen.queryByText(/Text-only evaluation on this HTTP address/i)
    ).not.toBeInTheDocument();
  });

  it("retries one transient failure with the same idempotency key", async () => {
    const user = userEvent.setup();
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockRejectedValueOnce(
        new ApiError(503, "service_unavailable", "Temporarily unavailable")
      )
      .mockResolvedValueOnce(result);

    renderPage();
    await startRoom(user);

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(2);
    expect(create.mock.calls[1]![1]).toBe(create.mock.calls[0]![1]);
  });

  it("rotates only an expired replay key and retries once", async () => {
    const user = userEvent.setup();
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockRejectedValueOnce(
        new ApiError(
          409,
          "idempotency_replay_expired",
          "The replay window ended"
        )
      )
      .mockResolvedValueOnce(result);

    renderPage();
    await startRoom(user);

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(2);
    expect(create.mock.calls[1]![1]).not.toBe(create.mock.calls[0]![1]);
    expect(create.mock.calls[1]![1]).toBe(
      window.sessionStorage.getItem("k-comms.instant-room.idempotency.v1")
    );
  });

  it("honors Retry-After before allowing another room request", async () => {
    const user = userEvent.setup();
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockRejectedValue(
      new ApiError(429, "rate_limited", "Slow down", undefined, 8)
    );

    renderPage();
    await startRoom(user);

    expect(
      await screen.findByText(/Room creation is rate-limited/i)
    ).toBeVisible();
    expect(
      screen.getByRole("button", { name: /Try again in/ })
    ).toHaveAttribute("aria-disabled", "true");
  });

  it("reuses the same key when a manual retry follows the bounded transient retry", async () => {
    const user = userEvent.setup();
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockRejectedValueOnce(
        new ApiError(503, "service_unavailable", "Unavailable")
      )
      .mockRejectedValueOnce(
        new ApiError(503, "service_unavailable", "Unavailable")
      )
      .mockResolvedValueOnce(result);

    renderPage();
    await startRoom(user);
    await user.click(await screen.findByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();

    expect(create).toHaveBeenCalledTimes(3);
    expect(new Set(create.mock.calls.map((call) => call[1])).size).toBe(1);
  });

  it("does not restore an unrelated standard guest invitation on the front door", async () => {
    const user = userEvent.setup();
    storeGuestSession(guestSession);
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue(result);

    renderPage();
    expect(create).not.toHaveBeenCalled();
    await startRoom(user);

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    expect(screen.queryByLabelText("Secure room link")).not.toBeInTheDocument();
  });

  it("preserves a cross-workspace account while using its guest room fallback", async () => {
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
    storeSession(accountSession);
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);

    renderPage();
    await startRoom(user, { displayName: undefined });

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(
      screen.queryByText("Account creation available")
    ).not.toBeInTheDocument();
    expect(
      window.sessionStorage.getItem("k-comms.session.v1")
    ).toContain("member-access");
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
    ).toContain("guest-access");

    await user.click(screen.getByRole("button", { name: "Leave room" }));

    await waitFor(() => expect(window.location.pathname).toBe("/app/"));
    expect(
      window.sessionStorage.getItem("k-comms.session.v1")
    ).toContain("member-access");
    expect(
      window.sessionStorage.getItem("k-comms.guest-session.v1")
    ).toBeNull();
  });

  it("keeps one stable room API and mounted route across guest account upgrade", async () => {
    const user = userEvent.setup();
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);
    const memberSocketTicket = vi
      .spyOn(ApiClient.prototype, "socketTicket")
      .mockResolvedValue({ ticket: "member-socket-ticket", expires_in: 60 });

    renderPage();
    await startRoom(user);
    await screen.findByRole("heading", { name: "Live room" });
    const firstApi = uiHarness.roomApis.at(-1);
    await user.click(
      screen.getByRole("button", { name: "Simulate account upgrade" })
    );

    await waitFor(() => expect(screen.getByText("human")).toBeVisible());
    expect(screen.getByText("1 participant")).toBeVisible();
    expect(uiHarness.roomApis.length).toBeGreaterThan(1);
    expect(uiHarness.roomApis.every((api) => api === firstApi)).toBe(true);
    await user.click(
      screen.getByRole("button", { name: "Request current socket ticket" })
    );
    await waitFor(() =>
      expect(uiHarness.delegatedTicket).toBe("member-socket-ticket")
    );
    expect(memberSocketTicket).toHaveBeenCalledTimes(1);
    expect(window.location.pathname).toBe("/");
    expect(screen.queryByLabelText("Secure room link")).not.toBeInTheDocument();
  });

  it("restores a converted member room and exact link without creating again", async () => {
    const user = userEvent.setup();
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue(result);
    const conversationLookup = vi
      .spyOn(ApiClient.prototype, "conversation")
      .mockResolvedValue(conversation);
    vi.spyOn(ApiClient.prototype, "me").mockResolvedValue({
      tenant: guestSession.tenant,
      user: {
        ...guestSession.user,
        account_type: "human",
        email: "host@example.test"
      },
      device: guestSession.device,
      capabilities: {
        allow_audio_calls: true,
        allow_video_calls: true,
        allow_public_channels: false,
        message_edit_window_seconds: 900,
        max_attachment_bytes: 10_000_000
      }
    });

    const first = renderPage();
    await startRoom(user);
    await screen.findByRole("heading", { name: "Live room" });
    await user.click(
      screen.getByRole("button", { name: "Simulate account upgrade" })
    );
    await waitFor(() => expect(screen.getByText("human")).toBeVisible());

    const stored =
      window.sessionStorage.getItem("k-comms.member-instant-room.v1") || "";
    expect(stored).toContain(room.id);
    expect(stored).toContain(shareUrl);
    expect(stored).not.toContain("guest-access");
    expect(stored).not.toContain("guest-refresh");
    expect(window.localStorage.getItem("k-comms.member-instant-room.v1")).toBeNull();
    first.unmount();

    renderPage();

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    expect(conversationLookup).toHaveBeenCalledWith(conversation.id);
    expect(screen.queryByLabelText("Secure room link")).not.toBeInTheDocument();
    expect(screen.getByText("human")).toBeVisible();
  });

  it("restores an ordinary signed-in member room without creating a duplicate", async () => {
    const user = userEvent.setup();
    const accountSession: Session = {
      ...guestSession,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...guestSession.user,
        account_type: "human",
        email: "host@example.test"
      }
    };
    const registeredRoom: InstantRoom = {
      ...room,
      owner_kind: "registered"
    };
    storeSession(accountSession);
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue({
        room: registeredRoom,
        conversation,
        share_url: shareUrl
      });
    const conversationLookup = vi
      .spyOn(ApiClient.prototype, "conversation")
      .mockResolvedValue(conversation);
    vi.spyOn(ApiClient.prototype, "me").mockResolvedValue({
      tenant: accountSession.tenant,
      user: accountSession.user,
      device: accountSession.device,
      capabilities: {
        allow_audio_calls: true,
        allow_video_calls: true,
        allow_public_channels: false,
        message_edit_window_seconds: 900,
        max_attachment_bytes: 10_000_000
      }
    });

    const first = renderPage();
    expect(await screen.findByText("Starting as")).toBeVisible();
    expect(
      screen.queryByRole("textbox", { name: "Your display name" })
    ).not.toBeInTheDocument();
    expect(screen.getByText(accountSession.user.display_name)).toBeVisible();
    await startRoom(user, { displayName: undefined });
    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create.mock.calls[0]?.[0]).not.toHaveProperty("display_name");
    first.unmount();
    renderPage();

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    expect(conversationLookup).toHaveBeenCalledWith(conversation.id);
    expect(screen.queryByLabelText("Secure room link")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Leave room" }));
    expect(
      window.sessionStorage.getItem("k-comms.member-instant-room.v1")
    ).toBeNull();
  });

  it("returns to the start form when a member session ends during room recovery", async () => {
    const user = userEvent.setup();
    const accountSession: Session = {
      ...guestSession,
      access_token: "member-access",
      refresh_token: "member-refresh",
      user: {
        ...guestSession.user,
        account_type: "human",
        email: "host@example.test"
      }
    };
    storeSession(accountSession);
    storeMemberInstantRoomContinuity(accountSession, {
      room: { ...room, owner_kind: "registered" },
      conversation,
      share_url: shareUrl
    });
    vi.spyOn(ApiClient.prototype, "conversation").mockImplementation(
      () => new Promise<Conversation>(() => undefined)
    );
    vi.spyOn(ApiClient.prototype, "me").mockResolvedValue({
      tenant: accountSession.tenant,
      user: accountSession.user,
      device: accountSession.device,
      capabilities: {
        allow_audio_calls: true,
        allow_video_calls: true,
        allow_public_channels: false,
        message_edit_window_seconds: 900,
        max_attachment_bytes: 10_000_000
      }
    });

    render(
      <SessionProvider>
        <BrowserRouter>
          <SessionLossControl />
          <InstantRoomPage />
        </BrowserRouter>
      </SessionProvider>
    );

    expect(await screen.findByText("Opening your room…")).toBeVisible();
    await user.click(
      screen.getByRole("button", { name: "Expire member session" })
    );

    expect(
      await screen.findByRole("heading", { name: "Start an instant room" })
    ).toBeVisible();
    expect(screen.queryByText("Opening your room…")).not.toBeInTheDocument();
    expect(
      window.sessionStorage.getItem("k-comms.member-instant-room.v1")
    ).toBeNull();
  });

  it("clears an unavailable restored room before starting a fresh visit", async () => {
    const user = userEvent.setup();
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue(result);
    const conversationLookup = vi
      .spyOn(ApiClient.prototype, "conversation")
      .mockRejectedValue(
        new ApiError(404, "instant_room_unavailable", "Room unavailable")
      );
    vi.spyOn(ApiClient.prototype, "me").mockResolvedValue({
      tenant: guestSession.tenant,
      user: {
        ...guestSession.user,
        account_type: "human",
        email: "host@example.test"
      },
      device: guestSession.device,
      capabilities: {
        allow_audio_calls: true,
        allow_video_calls: true,
        allow_public_channels: false,
        message_edit_window_seconds: 900,
        max_attachment_bytes: 10_000_000
      }
    });

    const first = renderPage();
    await startRoom(user);
    await screen.findByRole("heading", { name: "Live room" });
    await user.click(
      screen.getByRole("button", { name: "Simulate account upgrade" })
    );
    await waitFor(() =>
      expect(
        window.sessionStorage.getItem("k-comms.member-instant-room.v1")
      ).not.toBeNull()
    );
    first.unmount();
    renderPage();

    await waitFor(() => expect(conversationLookup).toHaveBeenCalled());
    expect(create).toHaveBeenCalledTimes(1);
    await startRoom(user, { displayName: undefined });
    await waitFor(() => expect(create).toHaveBeenCalledTimes(2));
    expect(create.mock.calls[1]![1]).not.toBe(create.mock.calls[0]![1]);
    expect(
      window.sessionStorage.getItem("k-comms.member-instant-room.v1")
    ).toBeNull();
  });

  it("keeps the link usable when the native share operation is cancelled", async () => {
    const user = userEvent.setup();
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);
    Object.defineProperty(navigator, "share", {
      configurable: true,
      value: vi.fn().mockRejectedValue(
        new DOMException("Cancelled", "AbortError")
      )
    });

    renderPage();
    await startRoom(user);
    await screen.findByRole("heading", { name: "Live room" });
    await openInviteDetails(user);
    await user.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(screen.getByLabelText("Secure room link")).not.toHaveValue(shareUrl)
    );
    expect(screen.queryByLabelText("Local QR")).not.toBeInTheDocument();
    expect(uiHarness.qrValue).toBe("");
  });
});
