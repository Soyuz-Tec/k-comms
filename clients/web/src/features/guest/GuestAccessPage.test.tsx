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
  GuestApiClient,
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
  loadGuestMessageCatchUp
} from "./GuestAccessPage";

const realtimeHarness = vi.hoisted(() => ({
  callbacks: null as null | {
    onStatus: (status: string) => void;
    onMessages: (messages: Message[]) => void;
    onReactionAdded: (event: ReactionEvent) => void;
    onReactionRemoved: (event: ReactionEvent) => void;
  }
}));

vi.mock("../calls/CallPanel", () => ({
  CallPanel: () => <div aria-label="Guest call controls">Audio and video controls</div>
}));

vi.mock("../../realtime", () => ({
  socketEndpoint: () => "/socket",
  RealtimeConversation: class {
    constructor(
      _endpoint: string,
      _ticket: string,
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
    }
    connect() { this.callbacks.onStatus("live"); }
    disconnect() { /* no-op */ }
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
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "visible"
    });
    vi.restoreAllMocks();
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
    expect(previewGuestLink).toHaveBeenCalledWith("single-use-secret");
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
    expect(previewGuestLink).toHaveBeenCalledWith("second-room-secret");
    expect(
      await screen.findByRole("button", { name: "Join conversation" })
    ).toBeVisible();
    expect(screen.queryByLabelText("Guest call controls")).not.toBeInTheDocument();
    expect(window.sessionStorage.getItem("k-comms.guest-session.v1")).toBeNull();
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
    ).toHaveAttribute("href", "/app");
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
    expect(window.location.pathname).toBe("/app");
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
