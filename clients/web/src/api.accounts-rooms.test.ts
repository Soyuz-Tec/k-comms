import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient, GuestApiClient } from "./api";
import type { Session } from "./types";

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

describe("public password recovery", () => {
  it("uses non-authenticated request and reset endpoints", async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(null, { status: 202 }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", null, vi.fn());

    await api.requestPasswordRecovery({ tenant_slug: "acme", email: "person@example.test" });
    await api.resetPassword({ token: "single-use", new_password: "correct horse battery staple" });

    const requestHeaders = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
    expect(requestHeaders.has("Authorization")).toBe(false);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/password-recovery/requests");
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(JSON.stringify({ tenant_slug: "acme", email: "person@example.test" }));
    expect(fetchMock.mock.calls[1]?.[0]).toBe("https://comms.test/api/v1/password-recovery/resets");
    expect(fetchMock.mock.calls[1]?.[1]?.body).toBe(JSON.stringify({ token: "single-use", new_password: "correct horse battery staple" }));
  });
});

describe("instant-room API", () => {
  const conversation = {
    id: "conversation-instant",
    tenant_id: "tenant-1",
    kind: "group" as const,
    title: "Instant room",
    counterpart_user_id: null,
    counterpart_display_name: null,
    visibility: "private" as const,
    latest_sequence: 0,
    inserted_at: "2026-07-24T12:00:00Z",
    updated_at: "2026-07-24T12:00:00Z"
  };
  const room = {
    id: "room-instant",
    conversation_id: conversation.id,
    owner_user_id: "guest-1",
    owner_kind: "guest",
    status: "active",
    participant_limit: 25,
    idle_since: null,
    expires_at: null,
    inserted_at: "2026-07-24T12:00:00Z",
    updated_at: "2026-07-24T12:00:00Z",
    generation: 7,
    reconnect_grace_seconds: 90,
    last_presence_at: "2026-07-24T12:00:30Z"
  };
  const key = "A".repeat(43);

  it("sends a 256-bit idempotency key and preserves the exact server share URL", async () => {
    const shareUrl =
      "https://public.example.test/join#guest=server%2Bfragment";
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({
        ...session,
        access_token: "guest-access",
        refresh_token: "guest-refresh",
        user: { ...session.user, account_type: "guest", email: null },
        room,
        conversation,
        share_url: shareUrl,
        capabilities: {
          allow_audio_calls: true,
          allow_video_calls: true,
          conversion_enabled: true,
          self_service_conversion: true
        }
      }), {
        status: 201,
        headers: { "content-type": "application/json" }
      })
    );
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", null, vi.fn());

    const created = await api.createInstantRoom({
      device: { name: "Browser", platform: "web" }
    }, key);

    expect(created.share_url).toBe(shareUrl);
    expect(created.guest_session).toMatchObject({
      access_token: "guest-access",
      share_url: shareUrl,
      instant_room: {
        id: "room-instant",
        owner_kind: "guest",
        owner_user_id: "guest-1",
        participant_limit: 25
      },
      capabilities: { self_service_conversion: true }
    });
    expect(created.room).not.toHaveProperty("generation");
    expect(created.room).not.toHaveProperty("reconnect_grace_seconds");
    expect(created.room).not.toHaveProperty("last_presence_at");
    const headers = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
    expect(headers.get("Idempotency-Key")).toBe(key);
    expect(headers.has("Authorization")).toBe(false);
  });

  it("maps only the public preview fields without tenant coupling", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({
        data: {
          room_title: "Instant room",
          status: "active",
          expires_at: null,
          participant_limit: 25,
          tenant_id: "must-not-cross-the-public-boundary",
          conversion_enabled: true
        }
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      })
    );
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await expect(api.previewInstantRoom("fragment-secret")).resolves.toEqual({
      room_title: "Instant room",
      status: "active",
      expires_at: null,
      participant_limit: 25
    });
    const headers = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
    expect(headers.has("Authorization")).toBe(false);
  });

  it("uses a separate idempotency key for guest admission and exposes Retry-After", async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: { code: "rate_limited", detail: "Slow down" } }), {
          status: 429,
          headers: {
            "content-type": "application/json",
            "retry-after": "12"
          }
        })
      );
    vi.stubGlobal("fetch", fetchMock);
    const api = new GuestApiClient("https://comms.test", null, vi.fn());

    await expect(api.joinInstantRoom({
      token: "fragment-secret",
      display_name: "Taylor",
      device: { name: "Browser", platform: "web" }
    }, key)).rejects.toMatchObject({
      status: 429,
      code: "rate_limited",
      retryAfterSeconds: 12
    });
    const headers = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
    expect(headers.get("Idempotency-Key")).toBe(key);
    expect(headers.has("Authorization")).toBe(false);
  });
});

describe("conversation membership concurrency", () => {
  it("sends the membership version when removing a member", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await api.removeConversationMember("conversation-1", "user-2", 7);

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/conversations/conversation-1/members/user-2");
    expect(fetchMock.mock.calls[0]?.[1]?.method).toBe("DELETE");
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(JSON.stringify({ version: 7 }));
  });
});
