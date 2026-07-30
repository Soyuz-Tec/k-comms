import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "./api";
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

function resolveHeadersWithStalledJson(options?: RequestInit): Promise<Response> {
  const signal = options?.signal;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const abort = () => controller.error(signal?.reason);
      if (signal?.aborted) {
        abort();
      } else {
        signal?.addEventListener("abort", abort, { once: true });
      }
    }
  });
  return Promise.resolve(new Response(body, {
    status: 200,
    headers: { "content-type": "application/json" }
  }));
}

describe("ApiClient session refresh", () => {
  it("bounds ordinary API requests and aborts the underlying fetch", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn<typeof fetch>((_input, options) => {
      return rejectWhenAborted(options);
    });
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    const assertion = expect(api.status()).rejects.toMatchObject({
      status: 408,
      code: "request_timeout",
      message: "K-Comms did not respond in time. Try again."
    });
    await vi.advanceTimersByTimeAsync(30_000);
    await assertion;

    expect(fetchMock.mock.calls[0]?.[1]?.signal?.aborted).toBe(true);
  });

  it("keeps the deadline active while a response body is being decoded", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn<typeof fetch>((_input, options) => {
      return resolveHeadersWithStalledJson(options);
    });
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    const assertion = expect(api.status()).rejects.toMatchObject({
      status: 408,
      code: "request_timeout"
    });
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(30_000);
    await assertion;

    expect(fetchMock.mock.calls[0]?.[1]?.signal?.aborted).toBe(true);
  });

  it("preserves a caller AbortSignal reason instead of reporting a timeout", async () => {
    const fetchMock = vi.fn<typeof fetch>((_input, options) => rejectWhenAborted(options));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());
    const controller = new AbortController();
    const callerReason = new DOMException("Caller stopped the request", "AbortError");

    const request = api.attachmentStatus("attachment-1", controller.signal);
    controller.abort(callerReason);

    await expect(request).rejects.toBe(callerReason);
  });

  it("bounds a stalled refresh without clearing the recoverable local session", async () => {
    vi.useFakeTimers();
    const onSession = vi.fn();
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ error: { detail: "expired" } }),
        { status: 401, headers: { "content-type": "application/json" } }
      ))
      .mockImplementationOnce((_input, options) => rejectWhenAborted(options));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, onSession);

    const assertion = expect(api.me()).rejects.toMatchObject({
      status: 408,
      code: "request_timeout"
    });
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(30_000);
    await assertion;

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(onSession).not.toHaveBeenCalled();
  });

  it("bounds a refresh whose headers arrive but JSON body stalls", async () => {
    vi.useFakeTimers();
    const onSession = vi.fn();
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(
        JSON.stringify({ error: { detail: "expired" } }),
        { status: 401, headers: { "content-type": "application/json" } }
      ))
      .mockImplementationOnce((_input, options) =>
        resolveHeadersWithStalledJson(options)
      );
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, onSession);

    const assertion = expect(api.me()).rejects.toMatchObject({
      status: 408,
      code: "request_timeout"
    });
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(30_000);
    await assertion;

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(onSession).not.toHaveBeenCalled();
  });

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

  it("never replays a delayed 401 under a different member account", async () => {
    let resolveRequest: ((response: Response) => void) | undefined;
    const delayedResponse = new Promise<Response>((resolve) => {
      resolveRequest = resolve;
    });
    const onSession = vi.fn();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(delayedResponse);
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, onSession);
    const replacement: Session = {
      ...session,
      access_token: "replacement-access",
      refresh_token: "replacement-refresh",
      tenant: { ...session.tenant, id: "tenant-2", slug: "other" },
      user: {
        ...session.user,
        id: "user-2",
        tenant_id: "tenant-2",
        email: "other@example.test"
      },
      device: { ...session.device, id: "device-2", user_id: "user-2" }
    };

    const request = api.me();
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

  it("discards a delayed authenticated response body after a member account switch", async () => {
    let resolveRequest: ((response: Response) => void) | undefined;
    const delayedResponse = new Promise<Response>((resolve) => {
      resolveRequest = resolve;
    });
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(delayedResponse);
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    const request = api.attachmentDownload("attachment-1");
    api.setSession({
      ...session,
      access_token: "replacement-access",
      refresh_token: "replacement-refresh",
      tenant: { ...session.tenant, id: "tenant-2", slug: "other" },
      user: { ...session.user, id: "user-2", tenant_id: "tenant-2" },
      device: { ...session.device, id: "device-2", user_id: "user-2" }
    });
    resolveRequest?.(new Response(JSON.stringify({
      data: {
        url: "https://objects.example.test/tenant-a-secret",
        approved_origin: "https://objects.example.test"
      }
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

  it("does not clear a replacement account when an old refresh is rejected", async () => {
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
    const api = new ApiClient("https://comms.test", session, onSession);
    const replacement: Session = {
      ...session,
      access_token: "replacement-access",
      refresh_token: "replacement-refresh",
      tenant: { ...session.tenant, id: "tenant-2", slug: "other" },
      user: { ...session.user, id: "user-2", tenant_id: "tenant-2" },
      device: { ...session.device, id: "device-2", user_id: "user-2" }
    };

    const request = api.me();
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    api.setSession(replacement);
    resolveRefresh?.(new Response(
      JSON.stringify({ error: { code: "invalid_refresh_token" } }),
      { status: 401, headers: { "content-type": "application/json" } }
    ));

    await expect(request).rejects.toMatchObject({ status: 401 });
    expect(onSession).not.toHaveBeenCalled();
  });

  it("retries a staggered old-token 401 under an already-refreshed same member session", async () => {
    const refreshed: Session = {
      ...session,
      access_token: "new-access",
      refresh_token: "new-refresh"
    };
    let resolveSecondRequest: ((response: Response) => void) | undefined;
    const secondResponse = new Promise<Response>((resolve) => {
      resolveSecondRequest = resolve;
    });
    let meRequests = 0;
    const fetchMock = vi.fn<typeof fetch>((input, options) => {
      const url = String(input);
      if (url.endsWith("/api/v1/sessions/refresh")) {
        return Promise.resolve(new Response(JSON.stringify(refreshed), {
          status: 200,
          headers: { "content-type": "application/json" }
        }));
      }
      if (!url.endsWith("/api/v1/me")) {
        return Promise.reject(new Error(`Unexpected request ${url}`));
      }
      meRequests += 1;
      if (meRequests === 1) {
        return Promise.resolve(new Response(
          JSON.stringify({ error: { code: "invalid_access_token", detail: "expired" } }),
          { status: 401, headers: { "content-type": "application/json" } }
        ));
      }
      if (meRequests === 2) return secondResponse;
      const headers = new Headers(options?.headers);
      expect(headers.get("Authorization")).toBe("Bearer new-access");
      return Promise.resolve(new Response(JSON.stringify({
        tenant: session.tenant,
        user: session.user,
        device: session.device,
        capabilities: {}
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      }));
    });
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, vi.fn());

    const first = api.me();
    const second = api.me();
    await expect(first).resolves.toMatchObject({ user: { id: "user-1" } });
    resolveSecondRequest?.(new Response(
      JSON.stringify({ error: { code: "invalid_access_token", detail: "expired" } }),
      { status: 401, headers: { "content-type": "application/json" } }
    ));
    await expect(second).resolves.toMatchObject({ user: { id: "user-1" } });

    const refreshCalls = fetchMock.mock.calls.filter(([input]) =>
      String(input).endsWith("/api/v1/sessions/refresh")
    );
    expect(refreshCalls).toHaveLength(1);
    expect(meRequests).toBe(4);
  });

  it("clears the local member session immediately and waits for durable logout revocation", async () => {
    let resolveRevocation: ((response: Response) => void) | undefined;
    const revocationResponse = new Promise<Response>((resolve) => {
      resolveRevocation = resolve;
    });
    const onSession = vi.fn();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(revocationResponse);
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://comms.test", session, onSession);

    let settled = false;
    const logout = api.logout().then(() => {
      settled = true;
    });
    expect(onSession).toHaveBeenCalledWith(null);
    await Promise.resolve();
    expect(settled).toBe(false);
    expect(fetchMock.mock.calls[0]?.[1]?.keepalive).toBe(true);

    resolveRevocation?.(new Response(null, { status: 204 }));
    await logout;
    expect(settled).toBe(true);
  });
});
