import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode, useEffect, useState } from "react";
import { BrowserRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiClient
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

vi.mock("@excalidraw/excalidraw", () => ({
  Excalidraw: () => <div aria-label="Excalidraw test canvas" />
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
    expect((displayName as HTMLInputElement).value).toMatch(/^Guest \d{4}$/);
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

    await user.clear(displayName);
    await user.click(start);

    const validation = screen.getByRole("alert");
    expect(validation).toHaveTextContent(
      "Enter your display name to continue."
    );
    expect(displayName).toHaveFocus();
    expect(displayName).toHaveAttribute("aria-invalid", "true");
    expect(displayName).toHaveAttribute(
      "aria-describedby",
      "instant-draft-display-name-help instant-draft-name-error"
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
      screen.getByRole("heading", { name: "Message. Draw. Share." })
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
    await waitFor(() =>
      expect(
        screen.getByRole("heading", { name: "Invite someone" })
      ).toHaveFocus()
    );
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
    expect(within(menu).queryByLabelText("Secure room link")).not.toBeInTheDocument();
    expect(within(menu).getByText("Secure room invite")).toBeVisible();
    expect(within(menu).getByRole("button", { name: "Copy invite link" })).toBeVisible();
    expect(within(menu).getByRole("button", { name: "Download QR code" })).toBeEnabled();
    expect(within(menu).getByRole("button", { name: "Share invite link" })).toBeVisible();
    expect(within(menu).getByRole("group", { name: "Invite actions" })).toBeVisible();
    expect(uiHarness.qrValue).toBe(shareUrl);

    await user.click(within(menu).getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("dialog", { name: "Room menu" })).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Local QR")).not.toBeInTheDocument();
  });

  it("copies and shares the exact invite only after explicit menu actions", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    const share = vi.fn().mockResolvedValue(undefined);
    const originalClipboard = Object.getOwnPropertyDescriptor(
      navigator,
      "clipboard"
    );
    const originalShare = Object.getOwnPropertyDescriptor(navigator, "share");
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });
    Object.defineProperty(navigator, "share", {
      configurable: true,
      value: share
    });
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);

    try {
      renderPage();
      await startRoom(user);
      await user.click(
        await screen.findByRole("button", { name: "Open room menu" })
      );
      const menu = screen.getByRole("dialog", { name: "Room menu" });

      await user.click(
        within(menu).getByRole("button", { name: "Copy invite link" })
      );
      expect(writeText).toHaveBeenCalledOnce();
      expect(writeText).toHaveBeenCalledWith(shareUrl);
      expect(within(menu).getByRole("status")).toHaveTextContent(
        "Secure link copied."
      );

      await user.click(
        within(menu).getByRole("button", { name: "Share invite link" })
      );
      expect(share).toHaveBeenCalledOnce();
      expect(share).toHaveBeenCalledWith({
        title: "Instant room on K-Comms",
        text: "Join my K-Comms room. No account is required.",
        url: shareUrl
      });
      expect(within(menu).getByRole("status")).toHaveTextContent(
        "Share sheet opened."
      );
    } finally {
      if (originalClipboard) {
        Object.defineProperty(navigator, "clipboard", originalClipboard);
      } else {
        Reflect.deleteProperty(navigator, "clipboard");
      }
      if (originalShare) {
        Object.defineProperty(navigator, "share", originalShare);
      } else {
        Reflect.deleteProperty(navigator, "share");
      }
    }
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
    expect(within(menu).queryByLabelText("Secure room link")).not.toBeInTheDocument();
    await user.click(
      within(menu).getByRole("button", { name: "Share invite link" })
    );

    await waitFor(() => expect(writeText).toHaveBeenCalledWith(shareUrl));
    const link = within(menu).getByLabelText("Secure room link");
    expect(link).toHaveValue(shareUrl);
    expect(
      within(menu).getByText(
        "Copy failed. The full link is visible so you can copy it manually."
      )
    ).toHaveAttribute("role", "status");
  });

  it("downloads the prepared QR as a generically named PNG", async () => {
    const user = userEvent.setup();
    const createObjectURL = vi.fn().mockReturnValue("blob:k-comms-room-invite");
    const revokeObjectURL = vi.fn();
    const originalCreateObjectURL = Object.getOwnPropertyDescriptor(
      URL,
      "createObjectURL"
    );
    const originalRevokeObjectURL = Object.getOwnPropertyDescriptor(
      URL,
      "revokeObjectURL"
    );
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: createObjectURL
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: revokeObjectURL
    });
    const click = vi
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(() => undefined);
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);

    try {
      renderPage();
      await startRoom(user);
      await user.click(
        await screen.findByRole("button", { name: "Open room menu" })
      );
      const menu = screen.getByRole("dialog", { name: "Room menu" });
      const download = within(menu).getByRole("button", {
        name: "Download QR code"
      });
      await waitFor(() => expect(download).toBeEnabled());
      let releaseObjectUrl: TimerHandler | undefined;
      const schedule = vi
        .spyOn(window, "setTimeout")
        .mockImplementation((handler, delay) => {
          expect(delay).toBe(30_000);
          releaseObjectUrl = handler;
          return 1 as unknown as ReturnType<typeof window.setTimeout>;
        });
      act(() => download.click());

      expect(createObjectURL).toHaveBeenCalledWith(expect.any(Blob));
      const blob = createObjectURL.mock.calls[0]![0] as Blob;
      expect(blob.type).toBe("image/png");
      expect(Array.from(new Uint8Array(await blob.arrayBuffer()))).toEqual([
        137, 80, 78, 71, 13, 10, 26, 10
      ]);
      expect(click).toHaveBeenCalledOnce();
      const anchor = click.mock.instances[0] as HTMLAnchorElement;
      expect(anchor.download).toBe("k-comms-room-invite-qr.png");
      expect(anchor.href).toBe("blob:k-comms-room-invite");
      expect(revokeObjectURL).not.toHaveBeenCalled();
      expect(schedule).toHaveBeenCalledWith(expect.any(Function), 30_000);
      act(() => {
        if (typeof releaseObjectUrl === "function") releaseObjectUrl();
      });
      expect(revokeObjectURL).toHaveBeenCalledWith("blob:k-comms-room-invite");
      schedule.mockRestore();
      expect(within(menu).getByRole("status")).toHaveTextContent(
        "QR code downloaded."
      );
    } finally {
      if (originalCreateObjectURL) {
        Object.defineProperty(URL, "createObjectURL", originalCreateObjectURL);
      } else {
        Reflect.deleteProperty(URL, "createObjectURL");
      }
      if (originalRevokeObjectURL) {
        Object.defineProperty(URL, "revokeObjectURL", originalRevokeObjectURL);
      } else {
        Reflect.deleteProperty(URL, "revokeObjectURL");
      }
    }
  });

  it("opens the native save sheet for a QR image on Apple mobile browsers", async () => {
    const user = userEvent.setup();
    const canShare = vi.fn().mockReturnValue(true);
    const share = vi.fn().mockResolvedValue(undefined);
    const createObjectURL = vi.fn();
    const originalUserAgent = Object.getOwnPropertyDescriptor(
      navigator,
      "userAgent"
    );
    const originalCanShare = Object.getOwnPropertyDescriptor(
      navigator,
      "canShare"
    );
    const originalShare = Object.getOwnPropertyDescriptor(navigator, "share");
    const originalCreateObjectURL = Object.getOwnPropertyDescriptor(
      URL,
      "createObjectURL"
    );
    Object.defineProperty(navigator, "userAgent", {
      configurable: true,
      value: "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X)"
    });
    Object.defineProperty(navigator, "canShare", {
      configurable: true,
      value: canShare
    });
    Object.defineProperty(navigator, "share", {
      configurable: true,
      value: share
    });
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: createObjectURL
    });
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);

    try {
      renderPage();
      await startRoom(user);
      await user.click(
        await screen.findByRole("button", { name: "Open room menu" })
      );
      const menu = screen.getByRole("dialog", { name: "Room menu" });
      const download = within(menu).getByRole("button", {
        name: "Download QR code"
      });
      await waitFor(() => expect(download).toBeEnabled());
      await user.click(download);

      expect(canShare).toHaveBeenCalledOnce();
      expect(share).toHaveBeenCalledOnce();
      const payload = share.mock.calls[0]![0] as ShareData;
      expect(payload.title).toBe("Room invite QR code");
      expect(payload.files).toHaveLength(1);
      expect(payload.files![0]).toEqual(
        expect.objectContaining({
          name: "k-comms-room-invite-qr.png",
          type: "image/png"
        })
      );
      expect(createObjectURL).not.toHaveBeenCalled();
      expect(within(menu).getByRole("status")).toHaveTextContent(
        "QR code save sheet opened."
      );
    } finally {
      if (originalUserAgent) {
        Object.defineProperty(navigator, "userAgent", originalUserAgent);
      } else {
        Reflect.deleteProperty(navigator, "userAgent");
      }
      if (originalCanShare) {
        Object.defineProperty(navigator, "canShare", originalCanShare);
      } else {
        Reflect.deleteProperty(navigator, "canShare");
      }
      if (originalShare) {
        Object.defineProperty(navigator, "share", originalShare);
      } else {
        Reflect.deleteProperty(navigator, "share");
      }
      if (originalCreateObjectURL) {
        Object.defineProperty(URL, "createObjectURL", originalCreateObjectURL);
      } else {
        Reflect.deleteProperty(URL, "createObjectURL");
      }
    }
  });

  it("reveals the manual link when native sharing fails without cancellation", async () => {
    const user = userEvent.setup();
    const share = vi.fn().mockRejectedValue(new Error("share unavailable"));
    const originalShare = Object.getOwnPropertyDescriptor(navigator, "share");
    Object.defineProperty(navigator, "share", {
      configurable: true,
      value: share
    });
    vi.spyOn(ApiClient.prototype, "createInstantRoom").mockResolvedValue(result);

    try {
      renderPage();
      await startRoom(user);
      await user.click(
        await screen.findByRole("button", { name: "Open room menu" })
      );
      const menu = screen.getByRole("dialog", { name: "Room menu" });
      expect(
        within(menu).queryByLabelText("Secure room link")
      ).not.toBeInTheDocument();

      await user.click(
        within(menu).getByRole("button", { name: "Share invite link" })
      );

      expect(share).toHaveBeenCalledOnce();
      expect(await within(menu).findByLabelText("Secure room link"))
        .toHaveValue(shareUrl);
      expect(within(menu).getByRole("status")).toHaveTextContent(
        "Sharing was not completed. The full link is visible so you can copy it manually."
      );
    } finally {
      if (originalShare) {
        Object.defineProperty(navigator, "share", originalShare);
      } else {
        Reflect.deleteProperty(navigator, "share");
      }
    }
  });
});
