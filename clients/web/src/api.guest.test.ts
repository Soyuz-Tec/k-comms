import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient, GuestApiClient } from "./api";
import type { GuestSession, Session } from "./types";

const session: Session = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  token_type: "Bearer",
  expires_in: 3600,
  received_at: Date.now(),
  tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" },
  user: { id: "user-1", tenant_id: "tenant-1", display_name: "Ada", email: "ada@example.test", role: "owner", status: "active" },
  device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
};

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function rejectWhenAborted(options?: RequestInit): Promise<Response> {
  return new Promise<Response>((_resolve, reject) => {
    const signal = options?.signal;
    if (!signal) return;
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}

describe("guest communication API", () => {
  const guestSession: GuestSession = {
    ...session,
    access_token: "guest-access",
    refresh_token: "guest-refresh",
    user: {
      ...session.user,
      id: "guest-1",
      account_type: "guest",
      email: null
    },
    conversation: {
      id: "conversation-1",
      tenant_id: "tenant-1",
      kind: "group",
      title: "Launch room",
      counterpart_user_id: null,
      counterpart_display_name: null,
      visibility: "private",
      latest_sequence: 0,
      inserted_at: "2026-07-24T12:00:00Z",
      updated_at: "2026-07-24T12:00:00Z"
    },
    capabilities: {
      allow_audio_calls: true,
      allow_video_calls: true,
      conversion_enabled: true,
      email_hint: "a***@example.test"
    }
  };

  it("applies the same bounded deadline to ordinary guest requests", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn<typeof fetch>((_input, options) => rejectWhenAborted(options));
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient("https://comms.test", guestSession, vi.fn());

    const assertion = expect(api.conversation()).rejects.toMatchObject({
      status: 408,
      code: "request_timeout"
    });
    await vi.advanceTimersByTimeAsync(30_000);
    await assertion;
  });

  it("opts guest and member history reads into retained sender labels", async () => {
    const page = {
      data: [],
      included: { sender_labels: [] },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockImplementation(() =>
        Promise.resolve(new Response(JSON.stringify(page), {
          status: 200,
          headers: { "content-type": "application/json" }
        }))
      );
    vi.stubGlobal("fetch", fetchMock);
    const memberApi = new ApiClient("https://comms.test", session, vi.fn());
    const guestApi = new GuestApiClient(
      "https://comms.test",
      guestSession,
      vi.fn()
    );

    await memberApi.messages("conversation-1", 7, 20, 30);
    await guestApi.messages(9, 40);

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "https://comms.test/api/v1/conversations/conversation-1/messages?after_sequence=7&limit=20&include=sender_labels&before_sequence=30"
    );
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://comms.test/api/v1/guest/conversation/messages?after_sequence=9&limit=40&include=sender_labels"
    );
  });

  it("refreshes rendered sender labels through bounded member and guest batches", async () => {
    const messageIds = Array.from(
      { length: 201 },
      (_, index) =>
        `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`
    );
    const fetchMock = vi.fn<typeof fetch>((_input, options) => {
      const requested = JSON.parse(String(options?.body)).message_ids as string[];
      return Promise.resolve(
        new Response(
          JSON.stringify({
            data: requested.map((id) => ({
              id,
              display_name: `Sender ${id.slice(-3)}`,
              redacted: false
            }))
          }),
          {
            status: 200,
            headers: { "content-type": "application/json" }
          }
        )
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    const memberApi = new ApiClient("https://comms.test", session, vi.fn());
    const guestApi = new GuestApiClient(
      "https://comms.test",
      guestSession,
      vi.fn()
    );

    const labels = await memberApi.messageSenderLabels(
      "conversation-1",
      [...messageIds].reverse().concat(messageIds[0]!)
    );
    await guestApi.messageSenderLabels([messageIds[0]!]);

    expect(labels).toHaveLength(201);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "https://comms.test/api/v1/conversations/conversation-1/message-sender-labels"
    );
    expect(
      JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body)).message_ids
    ).toEqual(messageIds.slice(0, 200));
    expect(
      JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)).message_ids
    ).toEqual(messageIds.slice(200));
    expect(fetchMock.mock.calls[2]?.[0]).toBe(
      "https://comms.test/api/v1/guest/conversation/message-sender-labels"
    );
  });

  it("opts thread reads into retained sender labels", async () => {
    const thread = {
      data: { root: {}, replies: [], reply_count: 0 },
      included: { sender_labels: [] },
      page: { has_more: false, next_before_sequence: null }
    };
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify(thread), {
        status: 200,
        headers: { "content-type": "application/json" }
      })
    );
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await expect(api.messageThread("conversation-1", "message-1", 17, 25)).resolves.toEqual(
      thread
    );

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "https://comms.test/api/v1/conversations/conversation-1/messages/message-1/thread?limit=25&include=sender_labels&before_sequence=17"
    );
  });

  it("creates and revokes a host link through canonical resources", async () => {
    const link = {
      id: "link-1",
      conversation_id: "conversation-1",
      expires_at: "2026-07-25T12:00:00Z",
      max_uses: 10,
      use_count: 0,
      status: "active" as const,
      share_url: "https://public.example.test/join#guest=one-token"
    };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: link, token: "one-token", share_url: link.share_url }),
        { status: 201, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: { ...link, revoked_at: "2026-07-24T13:00:00Z" } }),
        { status: 200, headers: { "content-type": "application/json" } }
      ));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await expect(api.createGuestLink("conversation-1", {
      expires_in_seconds: 86_400,
      max_uses: 10
    })).resolves.toMatchObject({ token: "one-token", url: link.share_url });
    await api.revokeGuestLink("conversation-1", "link-1");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "https://comms.test/api/v1/conversations/conversation-1/guest-links"
    );
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://comms.test/api/v1/conversations/conversation-1/guest-links/link-1"
    );
    expect(fetchMock.mock.calls[1]?.[1]?.method).toBe("DELETE");
  });

  it("keeps the one-time conversion code separate from the guest link", async () => {
    const verificationCode = "V".repeat(43);
    const link = {
      id: "link-convert",
      conversation_id: "conversation-1",
      expires_at: "2026-07-25T12:00:00Z",
      max_uses: 1,
      use_count: 0,
      conversion_enabled: true,
      email_hint: "a***@example.test",
      status: "active" as const,
      share_url: "https://public.example.test/join#guest=one-token"
    };
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(
      JSON.stringify({
        data: link,
        token: "one-token",
        share_url: link.share_url,
        conversion_verification_code: verificationCode
      }),
      { status: 201, headers: { "content-type": "application/json" } }
    ));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await expect(api.createGuestLink("conversation-1", {
      expires_in_seconds: 86_400,
      max_uses: 1,
      conversion_email: "ada@example.test"
    })).resolves.toMatchObject({
      token: "one-token",
      url: link.share_url,
      conversionVerificationCode: verificationCode
    });
    expect(link.share_url).not.toContain(verificationCode);
  });

  it("previews without credentials and keeps guest credentials isolated", async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        data: {
          room_title: "Operations room",
          expires_at: "2026-07-25T12:00:00Z",
          conversion_enabled: true,
          email_hint: "g***@example.test"
        }
      }), { status: 200, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: guestSession.conversation }),
        { status: 200, headers: { "content-type": "application/json" } }
      ));
    vi.stubGlobal("fetch", fetchMock);
    const publicApi = new GuestApiClient("https://comms.test", null, vi.fn());
    const guestApi = new GuestApiClient("https://comms.test", guestSession, vi.fn());

    await publicApi.previewGuestLink("one-token");
    await guestApi.conversation();

    expect(new Headers(fetchMock.mock.calls[0]?.[1]?.headers).has("Authorization")).toBe(false);
    expect(new Headers(fetchMock.mock.calls[1]?.[1]?.headers).get("Authorization")).toBe(
      "Bearer guest-access"
    );
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://comms.test/api/v1/guest/conversation"
    );
  });

  it("normalizes account conversion while preserving the room", async () => {
    const accountSession = {
      ...session,
      access_token: "member-access",
      refresh_token: "member-refresh"
    };
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(
      JSON.stringify({
        authentication: accountSession,
        conversation: guestSession.conversation,
        socket_handoff: {
          ticket: "converted-socket-ticket",
          expires_in: 60
        }
      }),
      { status: 200, headers: { "content-type": "application/json" } }
    ));
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient("https://comms.test", guestSession, vi.fn());

    await expect(api.convertAccount({
      email: "ada@example.test",
      verification_code: "A".repeat(43),
      password: "correct horse battery staple"
    })).resolves.toMatchObject({
      session: { access_token: "member-access" },
      conversation: { id: "conversation-1" },
      socket_handoff: {
        ticket: "converted-socket-ticket",
        expires_in: 60
      }
    });
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/guest/account");
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toMatchObject({
      email: "ada@example.test",
      verification_code: "A".repeat(43)
    });
  });

  it("normalizes host-authorized account conversion capabilities on admission", async () => {
    const onSession = vi.fn();
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(
      JSON.stringify(guestSession),
      { status: 201, headers: { "content-type": "application/json" } }
    ));
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient("https://comms.test", null, onSession);

    await expect(api.joinGuest({
      token: "one-token",
      display_name: "Ada Guest",
      device: { name: "Guest browser", platform: "web" }
    })).resolves.toMatchObject({
      capabilities: {
        allow_audio_calls: true,
        allow_video_calls: true,
        conversion_enabled: true,
        email_hint: "a***@example.test"
      }
    });

    expect(onSession).toHaveBeenCalledWith(expect.objectContaining({
      capabilities: expect.objectContaining({
        conversion_enabled: true,
        email_hint: "a***@example.test"
      })
    }));
  });

  it("reports when a restored guest session is no longer valid", async () => {
    const onSession = vi.fn();
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ error: { code: "invalid_access_token" } }),
        { status: 401, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ error: { code: "guest_session_unavailable" } }),
        { status: 401, headers: { "content-type": "application/json" } }
      ));
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient("https://comms.test", guestSession, onSession);

    await expect(api.conversation()).rejects.toMatchObject({ status: 401 });

    expect(onSession).toHaveBeenCalledWith(null, "access_ended");
  });

  it("keeps instant-room metadata across a guest token refresh", async () => {
    const onSession = vi.fn();
    const instantSession: GuestSession = {
      ...guestSession,
      instant_room: {
        id: "room-1",
        conversation_id: guestSession.conversation.id,
        owner_user_id: guestSession.user.id,
        owner_kind: "guest",
        status: "active",
        participant_limit: 25,
        idle_since: null,
        expires_at: null,
        inserted_at: "2026-07-24T12:00:00Z",
        updated_at: "2026-07-24T12:00:00Z"
      },
      share_url:
        "https://comms.example.test/join#guest=server-returned-secret"
    };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ error: { code: "invalid_access_token" } }),
        { status: 401, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({
          ...guestSession,
          access_token: "refreshed-access",
          refresh_token: "refreshed-refresh"
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: guestSession.conversation }),
        { status: 200, headers: { "content-type": "application/json" } }
      ));
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient(
      "https://comms.test",
      instantSession,
      onSession
    );

    await expect(api.conversation()).resolves.toMatchObject({
      id: "conversation-1"
    });
    expect(onSession).toHaveBeenCalledWith(expect.objectContaining({
      access_token: "refreshed-access",
      instant_room: expect.objectContaining({ id: "room-1" }),
      share_url: instantSession.share_url
    }));
  });

  it("never replays a delayed 401 under a different guest conversation", async () => {
    let resolveRequest: ((response: Response) => void) | undefined;
    const delayedResponse = new Promise<Response>((resolve) => {
      resolveRequest = resolve;
    });
    const onSession = vi.fn();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(delayedResponse);
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient(
      "https://comms.test",
      guestSession,
      onSession
    );
    const replacement: GuestSession = {
      ...guestSession,
      access_token: "replacement-guest-access",
      refresh_token: "replacement-guest-refresh",
      user: { ...guestSession.user, id: "guest-2" },
      device: {
        ...guestSession.device,
        id: "guest-device-2",
        user_id: "guest-2"
      },
      conversation: {
        ...guestSession.conversation,
        id: "conversation-2"
      }
    };

    const request = api.conversation();
    api.setSession(replacement);
    resolveRequest?.(new Response(
      JSON.stringify({ error: { code: "invalid_access_token", detail: "expired" } }),
      { status: 401, headers: { "content-type": "application/json" } }
    ));

    await expect(request).rejects.toMatchObject({
      status: 401,
      code: "invalid_access_token"
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(onSession).not.toHaveBeenCalled();
  });

  it("discards a delayed authenticated response body after the guest visit changes", async () => {
    let resolveRequest: ((response: Response) => void) | undefined;
    const delayedResponse = new Promise<Response>((resolve) => {
      resolveRequest = resolve;
    });
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(delayedResponse);
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient(
      "https://comms.test",
      guestSession,
      vi.fn()
    );

    const request = api.conversation();
    api.setSession({
      ...guestSession,
      access_token: "replacement-guest-access",
      refresh_token: "replacement-guest-refresh",
      user: { ...guestSession.user, id: "guest-2" },
      device: {
        ...guestSession.device,
        id: "guest-device-2",
        user_id: "guest-2"
      },
      conversation: { ...guestSession.conversation, id: "conversation-2" }
    });
    resolveRequest?.(new Response(JSON.stringify({
      data: guestSession.conversation
    }), {
      status: 200,
      headers: { "content-type": "application/json" }
    }));

    await expect(request).rejects.toMatchObject({
      status: 409,
      code: "session_changed"
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does not end a replacement guest visit when an old refresh is rejected", async () => {
    let resolveRefresh: ((response: Response) => void) | undefined;
    const refreshResponse = new Promise<Response>((resolve) => {
      resolveRefresh = resolve;
    });
    const onSession = vi.fn();
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ error: { code: "invalid_access_token", detail: "expired" } }),
        { status: 401, headers: { "content-type": "application/json" } }
      ))
      .mockReturnValueOnce(refreshResponse);
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient(
      "https://comms.test",
      guestSession,
      onSession
    );
    const replacement: GuestSession = {
      ...guestSession,
      access_token: "replacement-guest-access",
      refresh_token: "replacement-guest-refresh",
      user: { ...guestSession.user, id: "guest-2" },
      device: {
        ...guestSession.device,
        id: "guest-device-2",
        user_id: "guest-2"
      },
      conversation: {
        ...guestSession.conversation,
        id: "conversation-2"
      }
    };

    const request = api.conversation();
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    api.setSession(replacement);
    resolveRefresh?.(new Response(
      JSON.stringify({ error: { code: "invalid_refresh_token" } }),
      { status: 401, headers: { "content-type": "application/json" } }
    ));

    await expect(request).rejects.toMatchObject({ status: 401 });
    expect(onSession).not.toHaveBeenCalled();
  });

  it("retries a staggered old-token 401 under an already-refreshed same guest visit", async () => {
    const refreshed = {
      ...guestSession,
      access_token: "new-guest-access",
      refresh_token: "new-guest-refresh"
    };
    let resolveSecondRequest: ((response: Response) => void) | undefined;
    const secondResponse = new Promise<Response>((resolve) => {
      resolveSecondRequest = resolve;
    });
    let conversationRequests = 0;
    const fetchMock = vi.fn<typeof fetch>((input, options) => {
      const url = String(input);
      if (url.endsWith("/api/v1/guest/sessions/refresh")) {
        return Promise.resolve(new Response(JSON.stringify(refreshed), {
          status: 200,
          headers: { "content-type": "application/json" }
        }));
      }
      if (!url.endsWith("/api/v1/guest/conversation")) {
        return Promise.reject(new Error(`Unexpected request ${url}`));
      }
      conversationRequests += 1;
      if (conversationRequests === 1) {
        return Promise.resolve(new Response(
          JSON.stringify({ error: { code: "invalid_access_token", detail: "expired" } }),
          { status: 401, headers: { "content-type": "application/json" } }
        ));
      }
      if (conversationRequests === 2) return secondResponse;
      const headers = new Headers(options?.headers);
      expect(headers.get("Authorization")).toBe("Bearer new-guest-access");
      return Promise.resolve(new Response(JSON.stringify({
        data: guestSession.conversation
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      }));
    });
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient(
      "https://comms.test",
      guestSession,
      vi.fn()
    );

    const first = api.conversation();
    const second = api.conversation();
    await expect(first).resolves.toMatchObject({ id: "conversation-1" });
    resolveSecondRequest?.(new Response(
      JSON.stringify({ error: { code: "invalid_access_token", detail: "expired" } }),
      { status: 401, headers: { "content-type": "application/json" } }
    ));
    await expect(second).resolves.toMatchObject({ id: "conversation-1" });

    const refreshCalls = fetchMock.mock.calls.filter(([input]) =>
      String(input).endsWith("/api/v1/guest/sessions/refresh")
    );
    expect(refreshCalls).toHaveLength(1);
    expect(conversationRequests).toBe(4);
  });

  it("clears the guest visit immediately and waits for durable logout revocation", async () => {
    let resolveRevocation: ((response: Response) => void) | undefined;
    const revocationResponse = new Promise<Response>((resolve) => {
      resolveRevocation = resolve;
    });
    const onSession = vi.fn();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(revocationResponse);
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient(
      "https://comms.test",
      guestSession,
      onSession
    );

    let settled = false;
    const logout = api.logout().then(() => {
      settled = true;
    });
    expect(onSession).toHaveBeenCalledWith(null, "logout");
    await Promise.resolve();
    expect(settled).toBe(false);
    expect(fetchMock.mock.calls[0]?.[1]?.keepalive).toBe(true);

    resolveRevocation?.(new Response(null, { status: 204 }));
    await logout;
    expect(settled).toBe(true);
  });

  it("uses only conversation-scoped guest routes for audio and video call lifecycle", async () => {
    const call = {
      id: "call-audio",
      conversation_id: "conversation-1",
      started_by_user_id: "guest-1",
      media_kind: "audio" as const,
      status: "active" as const,
      started_at: "2026-07-24T12:00:00Z",
      expires_at: "2026-07-24T13:00:00Z",
      can_end: true
    };
    const credential = {
      server_url: "wss://media.example.test",
      participant_token: "short-lived-token",
      expires_in: 120
    };
    const sessionResponse = { data: call, credential };
    const videoCall = { ...call, id: "call-video", media_kind: "video" as const };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(
        JSON.stringify(sessionResponse),
        { status: 201, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify(sessionResponse),
        { status: 200, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: { ...call, status: "ended" } }),
        { status: 200, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: videoCall, credential }),
        { status: 201, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: videoCall, credential }),
        { status: 200, headers: { "content-type": "application/json" } }
      ))
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ data: { ...videoCall, status: "ended" } }),
        { status: 200, headers: { "content-type": "application/json" } }
      ));
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient("https://comms.test", guestSession, vi.fn());

    await api.startCall("caller-controlled-room", "audio");
    await api.joinCall("caller-controlled-room", "call-audio");
    await api.endCall("caller-controlled-room", "call-audio");
    await api.startCall("caller-controlled-room", "video");
    await api.joinCall("caller-controlled-room", "call-video");
    await api.endCall("caller-controlled-room", "call-video");

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "https://comms.test/api/v1/guest/conversation/calls",
      "https://comms.test/api/v1/guest/conversation/calls/call-audio/join",
      "https://comms.test/api/v1/guest/conversation/calls/call-audio/end",
      "https://comms.test/api/v1/guest/conversation/calls",
      "https://comms.test/api/v1/guest/conversation/calls/call-video/join",
      "https://comms.test/api/v1/guest/conversation/calls/call-video/end"
    ]);
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(JSON.stringify({ media_kind: "audio" }));
    expect(fetchMock.mock.calls[3]?.[1]?.body).toBe(JSON.stringify({ media_kind: "video" }));
    expect(fetchMock.mock.calls.every(([, options]) =>
      new Headers(options?.headers).get("Authorization") === "Bearer guest-access"
    )).toBe(true);
    expect(JSON.stringify(fetchMock.mock.calls)).not.toContain("caller-controlled-room");
  });
});
