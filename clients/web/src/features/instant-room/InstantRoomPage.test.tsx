import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { BrowserRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiClient,
  ApiError,
  storeGuestSession,
  storeSession
} from "../../api";
import { SessionProvider } from "../../app/session";
import type {
  Conversation,
  GuestSession,
  InstantRoom,
  InstantRoomResult,
  Session
} from "../../types";
import { InstantRoomPage } from "./InstantRoomPage";

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
    roomBanner
  }: {
    api: { socketTicket: () => Promise<{ ticket: string; expires_in: number }> };
    initialSession: GuestSession;
    onConverted: (session: GuestSession, conversation: Conversation) => void;
    onLeave: () => void;
    roomBanner?: React.ReactNode;
  }) => {
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
        {roomBanner}
      </main>
    );
  }
}));

const conversation: Conversation = {
  id: "conversation-instant",
  tenant_id: "tenant-public",
  kind: "group",
  title: "Instant room",
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

describe("InstantRoomPage", () => {
  beforeEach(() => {
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/");
    uiHarness.qrValue = "";
    uiHarness.shellRenders = 0;
    uiHarness.roomApis = [];
    uiHarness.delegatedTicket = "";
    vi.restoreAllMocks();
  });

  it("creates once under StrictMode, enters the room and shares the exact server URL", async () => {
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue(result);

    renderPage(true);

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    const [input, key] = create.mock.calls[0]!;
    expect(input).toEqual(expect.objectContaining({
      device: expect.objectContaining({ platform: "web" })
    }));
    expect(key).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(screen.getByLabelText("Secure room link")).toHaveValue(shareUrl);
    expect(uiHarness.qrValue).toBe(shareUrl);
    expect(screen.getByText(/remains available for 1 hour/i)).toBeVisible();

    const stored = window.sessionStorage.getItem("k-comms.guest-session.v1") || "";
    expect(stored).toContain("guest-access");
    expect(window.localStorage.getItem("k-comms.guest-session.v1")).toBeNull();
  });

  it("retries one transient failure with the same idempotency key", async () => {
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockRejectedValueOnce(
        new ApiError(503, "service_unavailable", "Temporarily unavailable")
      )
      .mockResolvedValueOnce(result);

    renderPage();

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(2);
    expect(create.mock.calls[1]![1]).toBe(create.mock.calls[0]![1]);
  });

  it("rotates only an expired replay key and retries once", async () => {
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

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(2);
    expect(create.mock.calls[1]![1]).not.toBe(create.mock.calls[0]![1]);
    expect(create.mock.calls[1]![1]).toBe(
      window.sessionStorage.getItem("k-comms.instant-room.idempotency.v1")
    );
  });

  it("honors Retry-After before allowing another room request", async () => {
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockRejectedValue(
      new ApiError(429, "rate_limited", "Slow down", undefined, 8)
    );

    renderPage();

    expect(
      await screen.findByText(/Room creation is rate-limited/i)
    ).toBeVisible();
    expect(screen.getByRole("button", { name: /Try again in/ })).toBeDisabled();
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
    await user.click(await screen.findByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();

    expect(create).toHaveBeenCalledTimes(3);
    expect(new Set(create.mock.calls.map((call) => call[1])).size).toBe(1);
  });

  it("does not restore an unrelated standard guest invitation on the front door", async () => {
    storeGuestSession(guestSession);
    const create = vi
      .spyOn(ApiClient.prototype, "createInstantRoom")
      .mockResolvedValue(result);

    renderPage();

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    expect(screen.getByLabelText("Secure room link")).toHaveValue(shareUrl);
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

    await waitFor(() => expect(window.location.pathname).toBe("/app"));
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
    await screen.findByRole("heading", { name: "Live room" });
    const firstApi = uiHarness.roomApis.at(-1);
    await user.click(
      screen.getByRole("button", { name: "Simulate account upgrade" })
    );

    await waitFor(() => expect(screen.getByText("human")).toBeVisible());
    expect(screen.getByText(/remains available for 24 hours/i)).toBeVisible();
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
    expect(screen.getByLabelText("Secure room link")).toHaveValue(shareUrl);
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
    expect(screen.getByLabelText("Secure room link")).toHaveValue(shareUrl);
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
    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    first.unmount();
    renderPage();

    expect(await screen.findByRole("heading", { name: "Live room" })).toBeVisible();
    expect(create).toHaveBeenCalledTimes(1);
    expect(conversationLookup).toHaveBeenCalledWith(conversation.id);
    expect(screen.getByLabelText("Secure room link")).toHaveValue(shareUrl);
    await user.click(screen.getByRole("button", { name: "Leave room" }));
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
    await screen.findByRole("heading", { name: "Live room" });
    await user.click(screen.getByRole("button", { name: "Share" }));

    await waitFor(() =>
      expect(screen.getByLabelText("Secure room link")).toHaveValue(shareUrl)
    );
    expect(uiHarness.qrValue).toBe(shareUrl);
  });
});
