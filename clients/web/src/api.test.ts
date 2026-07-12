import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient, downloadUrl } from "./api";
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

afterEach(() => vi.unstubAllGlobals());

describe("ApiClient session refresh", () => {
  it("keeps the local session when refresh infrastructure is temporarily unavailable", async () => {
    const onSession = vi.fn();
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { detail: "expired" } }), { status: 401, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response("unavailable", { status: 503 }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, onSession);

    await expect(api.me()).rejects.toThrow("temporarily unavailable");
    expect(onSession).not.toHaveBeenCalled();
  });

  it("clears the session when the refresh token is definitively rejected", async () => {
    const onSession = vi.fn();
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { detail: "expired" } }), { status: 401, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { detail: "invalid" } }), { status: 401, headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, onSession);

    await expect(api.me()).rejects.toThrow("expired");
    expect(onSession).toHaveBeenCalledWith(null);
  });

  it("keeps logout final when an earlier refresh resolves afterward", async () => {
    const refreshed = { ...session, access_token: "new-access", refresh_token: "new-refresh" };
    let resolveRefresh: ((response: Response) => void) | undefined;
    const refreshResponse = new Promise<Response>((resolve) => { resolveRefresh = resolve; });
    const onSession = vi.fn();
    const fetchMock = vi.fn<typeof fetch>((input, options) => {
      const url = String(input);
      if (url.endsWith("/api/v1/sessions/refresh")) return refreshResponse;
      if (url.endsWith("/api/v1/sessions/current") && options?.method === "DELETE") {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      return Promise.reject(new Error(`Unexpected request ${url}`));
    });
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, onSession);

    const refreshing = api.refreshSession();
    await api.logout();
    resolveRefresh?.(new Response(JSON.stringify(refreshed), { status: 200, headers: { "content-type": "application/json" } }));
    await expect(refreshing).resolves.toBeNull();

    expect(onSession).toHaveBeenLastCalledWith(null);
    expect(onSession).not.toHaveBeenCalledWith(expect.objectContaining({ access_token: "new-access" }));
  });
});

describe("presigned URL validation", () => {
  it("accepts an exact approved HTTPS origin", () => {
    expect(downloadUrl({
      url: "https://objects.example.test/files/report.pdf?signature=abc",
      approved_origin: "https://objects.example.test"
    })).toBe("https://objects.example.test/files/report.pdf?signature=abc");
  });

  it("rejects origin substitution, credentials, and non-local HTTP", () => {
    expect(downloadUrl({ url: "https://evil.example.test/file", approved_origin: "https://objects.example.test" })).toBeNull();
    expect(downloadUrl({ url: "https://user:pass@objects.example.test/file", approved_origin: "https://objects.example.test" })).toBeNull();
    expect(downloadUrl({ url: "http://objects.example.test/file", approved_origin: "http://objects.example.test" })).toBeNull();
  });
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

describe("platform operations boundary", () => {
  it("uses the platform-operator endpoint instead of tenant operations", async () => {
    const snapshot = { generated_at: "2026-07-12T10:00:00Z", database: { status: "ready" }, outbox: { pending: 0, published: 0 }, notifications: {}, webhooks: {}, attachments: {}, queues: [], providers: {} };
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(JSON.stringify({ data: snapshot }), { status: 200, headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await expect(api.platformOperations()).resolves.toEqual(snapshot);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/platform/ops");
  });
});

describe("public channel API", () => {
  it("encodes discovery cursors and versioned join/leave requests", async () => {
    const page = { data: [], page: { limit: 25, has_more: false, next_cursor: null } };
    const membershipResponse = { data: { conversation: { id: "channel-1" }, membership: { id: "membership-1", version: 4 } }, replayed: false };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify(page), { status: 200, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify(membershipResponse), { status: 201, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify(membershipResponse), { status: 200, headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await api.discoverPublicChannels("project alpha", 25, "opaque+/=");
    await api.joinPublicChannel("channel-1");
    await api.leavePublicChannel("channel-1", 4);

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/channels/discover?q=project+alpha&limit=25&cursor=opaque%2B%2F%3D");
    expect(fetchMock.mock.calls[1]?.[1]?.method).toBe("POST");
    expect(fetchMock.mock.calls[2]?.[1]?.method).toBe("DELETE");
    expect(fetchMock.mock.calls[2]?.[1]?.body).toBe(JSON.stringify({ version: 4 }));
  });
});

describe("service account administration API", () => {
  it("uses versioned reason-bearing lifecycle endpoints and returns credentials only from writes", async () => {
    const account = { id: "service-1", version: 4, scopes: ["messages:write"] };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: [account] }), { status: 200, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: account, credential: "kcsa_service.secret" }), { status: 201, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: { ...account, version: 5 }, credential: "kcsa_service.rotated" }), { status: 200, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: { ...account, version: 6, status: "revoked" } }), { status: 200, headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await api.serviceAccounts();
    await api.createServiceAccount({ name: "Bot", scopes: ["messages:write"], expires_at: "2026-10-01T00:00:00Z", reason: "Automate release notices" });
    await api.rotateServiceAccount("service-1", 4, "Scheduled rotation");
    await api.revokeServiceAccount("service-1", 5, "Integration retired");

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/admin/service-accounts");
    expect(fetchMock.mock.calls[1]?.[1]?.method).toBe("POST");
    expect(fetchMock.mock.calls[2]?.[0]).toBe("https://comms.test/api/v1/admin/service-accounts/service-1/rotate");
    expect(fetchMock.mock.calls[2]?.[1]?.body).toBe(JSON.stringify({ version: 4, reason: "Scheduled rotation" }));
    expect(fetchMock.mock.calls[3]?.[0]).toBe("https://comms.test/api/v1/admin/service-accounts/service-1/revoke");
    expect(fetchMock.mock.calls[3]?.[1]?.body).toBe(JSON.stringify({ version: 5, reason: "Integration retired" }));
  });
});

describe("governance and audit evidence API", () => {
  it("sends the required deletion transition reason field", async () => {
    const updated = { id: "deletion-1", status: "approved", version: 2 };
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(JSON.stringify({ data: updated }), {
      status: 200,
      headers: { "content-type": "application/json" }
    }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await api.updateDeletionRequest("deletion-1", {
      status: "approved",
      version: 1,
      transition_reason: "Approved by the data owner"
    });

    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(JSON.stringify({
      status: "approved",
      version: 1,
      transition_reason: "Approved by the data owner"
    }));
  });

  it("maps legal-hold targets to the exact backend fields", async () => {
    const hold = { id: "hold-1", scope_type: "tenant" };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ data: hold }), {
        status: 201,
        headers: { "content-type": "application/json" }
      })));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await api.createLegalHold({ name: "Workspace", reason: "Investigation", scope_type: "tenant" });
    await api.createLegalHold({ name: "Person", reason: "Investigation", scope_type: "user", target_id: "user-2" });
    await api.createLegalHold({ name: "Channel", reason: "Investigation", scope_type: "conversation", target_id: "conversation-1" });

    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({
      name: "Workspace", reason: "Investigation", scope_type: "tenant"
    });
    expect(JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body))).toEqual({
      name: "Person", reason: "Investigation", scope_type: "user", subject_user_id: "user-2"
    });
    expect(JSON.parse(String(fetchMock.mock.calls[2]?.[1]?.body))).toEqual({
      name: "Channel", reason: "Investigation", scope_type: "conversation", conversation_id: "conversation-1"
    });
  });

  it("downloads authenticated audit CSV with bounded filters and safe response metadata", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response("\"action\"\r\n\"user.created\"\r\n", {
      status: 200,
      headers: {
        "content-type": "text/csv; charset=utf-8",
        "content-disposition": "attachment; filename=\"k-comms-audit-20260712T100000Z.csv\"",
        "x-export-row-count": "1",
        "x-export-truncated": "true"
      }
    }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    const file = await api.exportAuditEvents({ q: "user.created", limit: 5_000 });

    expect(file).toMatchObject({
      filename: "k-comms-audit-20260712T100000Z.csv",
      count: 1,
      truncated: true
    });
    await expect(file.blob.text()).resolves.toContain("user.created");
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/admin/audit-events/export");
    expect(fetchMock.mock.calls[0]?.[1]?.method).toBe("POST");
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(JSON.stringify({ q: "user.created", limit: 5_000 }));
    const headers = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
    expect(headers.get("Accept")).toBe("text/csv");
    expect(headers.get("Authorization")).toBe("Bearer access-token");
  });
});

describe("browser push API", () => {
  it("uses only authenticated per-device subscription endpoints", async () => {
    const record = { id: "push-1", device_id: "device-1", endpoint_hint: "push.example.test", status: "active", inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: { available: true, vapid_public_key: "public" } }), { status: 200, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: [] }), { status: 200, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: record, replayed: false }), { status: 201, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: { ...record, status: "revoked" } }), { status: 200, headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    await api.pushSubscriptionConfig();
    await api.pushSubscriptions();
    await api.registerPushSubscription({ endpoint: "https://push.example.test/send/capability", expiration_time: null, keys: { p256dh: "public", auth: "auth" } });
    await api.revokePushSubscription("push-1");

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://comms.test/api/v1/me/push-subscriptions/config");
    expect(fetchMock.mock.calls[1]?.[0]).toBe("https://comms.test/api/v1/me/push-subscriptions");
    expect(fetchMock.mock.calls[2]?.[1]?.method).toBe("POST");
    expect(fetchMock.mock.calls[3]?.[0]).toBe("https://comms.test/api/v1/me/push-subscriptions/push-1");
    expect(fetchMock.mock.calls[3]?.[1]?.method).toBe("DELETE");
  });
});
