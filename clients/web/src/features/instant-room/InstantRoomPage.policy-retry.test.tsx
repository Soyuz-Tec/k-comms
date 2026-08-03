import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode, useEffect, useState } from "react";
import { BrowserRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiClient,
  ApiError
} from "../../api";
import { SessionProvider } from "../../app/session";
import type {
  Conversation,
  GuestSession,
  InstantRoom,
  InstantRoomResult
} from "../../types";
import { InstantRoomPage } from "./InstantRoomPage";

const uiHarness = vi.hoisted(() => ({
  qrValue: "",
  shellRenders: 0,
  roomApis: [] as unknown[],
  delegatedTicket: ""
}));

vi.mock("../whiteboard/KCommsDrawingCanvas", () => ({
  KCommsDrawingCanvas: () => <div aria-label="Drawing test canvas" />
}));

vi.mock("../guest/QrCode", () => ({
  QrCode: ({
    value,
    onReady
  }: {
    value: string;
    onReady?: (source: string) => void;
  }) => {
    uiHarness.qrValue = value;
    useEffect(() => {
      onReady?.("data:image/png;base64,iVBORw0KGgo=");
    }, [onReady, value]);
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
    screen.getByRole("button", { name: "Create room" })
  );
}

describe("InstantRoomPage", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/");
    uiHarness.qrValue = "";
    uiHarness.shellRenders = 0;
    uiHarness.roomApis = [];
    uiHarness.delegatedTicket = "";
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
      screen.getByRole("button", { name: "Create room" })
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
});
