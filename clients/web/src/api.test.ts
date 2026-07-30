import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ApiClient,
  downloadUrl,
  GuestApiClient,
  isApprovedPrivateLanObjectUrl,
  sha256,
  uploadToPresignedTarget
} from "./api";
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

describe("attachment checksums", () => {
  it("hashes uploads when SubtleCrypto is unavailable on plain LAN HTTP", async () => {
    vi.stubGlobal("crypto", {});

    await expect(
      sha256(new File(["abc"], "known-vector.txt", { type: "text/plain" }))
    ).resolves.toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
  });
});

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

  it("permits cleartext object access only on the exact current RFC1918 host", () => {
    const target = new URL("http://192.168.1.177:5900/k-comms/file");
    const approved = new URL("http://192.168.1.177:5900");

    expect(
      isApprovedPrivateLanObjectUrl(
        target,
        approved,
        new URL("http://192.168.1.177:4188/app")
      )
    ).toBe(true);
    expect(
      isApprovedPrivateLanObjectUrl(
        target,
        approved,
        new URL("https://192.168.1.177:4188/app")
      )
    ).toBe(false);
    expect(
      isApprovedPrivateLanObjectUrl(
        target,
        approved,
        new URL("http://192.168.1.178:4188/app")
      )
    ).toBe(false);
    expect(
      isApprovedPrivateLanObjectUrl(
        target,
        new URL("http://192.168.1.177:5901"),
        new URL("http://192.168.1.177:4188/app")
      )
    ).toBe(false);
    expect(
      isApprovedPrivateLanObjectUrl(
        new URL("http://203.0.113.10:5900/k-comms/file"),
        new URL("http://203.0.113.10:5900"),
        new URL("http://203.0.113.10:4188/app")
      )
    ).toBe(false);
  });

  it("keeps large object uploads on the caller-controlled signal without an API deadline", async () => {
    const callerController = new AbortController();
    const { requests, restore } = stubUploadTransport();
    const fetchMock = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchMock);

    const upload = uploadToPresignedTarget(
      descriptor(),
      new File(["report"], "report.pdf", { type: "application/pdf" }),
      callerController.signal
    );
    requests[0]?.succeed(204);
    await upload;

    // The object transfer must not inherit the API deadline that wraps ordinary
    // requests: a large file over a slow link would be cut off mid-transfer.
    expect(fetchMock).not.toHaveBeenCalled();
    expect(requests[0]?.aborted).toBe(false);
    restore();
  });

  it("aborts the transfer when the caller's signal fires", async () => {
    const callerController = new AbortController();
    const { requests, restore } = stubUploadTransport();

    const upload = uploadToPresignedTarget(
      descriptor(),
      new File(["report"], "report.pdf", { type: "application/pdf" }),
      callerController.signal
    );
    callerController.abort();

    await expect(upload).rejects.toMatchObject({ name: "AbortError" });
    expect(requests[0]?.aborted).toBe(true);
    restore();
  });

  it("rejects an upload that was already cancelled before it started", async () => {
    const callerController = new AbortController();
    callerController.abort();
    const { requests, restore } = stubUploadTransport();

    await expect(
      uploadToPresignedTarget(
        descriptor(),
        new File(["report"], "report.pdf", { type: "application/pdf" }),
        callerController.signal
      )
    ).rejects.toMatchObject({ name: "AbortError" });
    expect(requests).toHaveLength(0);
    restore();
  });

  it("reports transferred fractions and settles at one", async () => {
    const { requests, restore } = stubUploadTransport();
    const seen: number[] = [];

    const upload = uploadToPresignedTarget(
      descriptor(),
      new File(["report"], "report.pdf", { type: "application/pdf" }),
      undefined,
      (fraction) => seen.push(fraction)
    );
    requests[0]?.progress(25, 100);
    requests[0]?.progress(50, 100);
    requests[0]?.succeed(204);
    await upload;

    expect(seen).toEqual([0.25, 0.5, 1]);
    restore();
  });

  it("stays indeterminate when the browser cannot report a total", async () => {
    const { requests, restore } = stubUploadTransport();
    const seen: number[] = [];

    const upload = uploadToPresignedTarget(
      descriptor(),
      new File(["report"], "report.pdf", { type: "application/pdf" }),
      undefined,
      (fraction) => seen.push(fraction)
    );
    // A chunked transfer has no computable length; a fabricated fraction would
    // be worse than none.
    requests[0]?.progress(25, 0);
    requests[0]?.succeed(204);
    await upload;

    expect(seen).toEqual([1]);
    restore();
  });

  it("surfaces a non-success status from the object store", async () => {
    const { requests, restore } = stubUploadTransport();

    const upload = uploadToPresignedTarget(
      descriptor(),
      new File(["report"], "report.pdf", { type: "application/pdf" })
    );
    requests[0]?.succeed(403);

    await expect(upload).rejects.toThrow("Object upload failed with status 403");
    restore();
  });
});

function descriptor() {
  return {
    url: "https://objects.example.test/files/report.pdf?signature=abc",
    approved_origin: "https://objects.example.test",
    method: "PUT"
  };
}

interface FakeUploadRequest {
  aborted: boolean;
  progress: (loaded: number, total: number) => void;
  succeed: (status: number) => void;
  fail: () => void;
}

/**
 * jsdom's XMLHttpRequest performs a real network request, so the transport is
 * replaced wholesale to drive upload events deterministically.
 */
function stubUploadTransport() {
  const requests: FakeUploadRequest[] = [];
  const original = globalThis.XMLHttpRequest;

  class FakeXhr {
    status = 0;
    upload = new EventTarget();
    private readonly listeners = new EventTarget();
    private record: FakeUploadRequest = {
      aborted: false,
      progress: () => undefined,
      succeed: () => undefined,
      fail: () => undefined
    };

    open() {
      /* no transport is opened */
    }
    setRequestHeader() {
      /* headers are irrelevant to the stub */
    }
    addEventListener(type: string, listener: EventListener) {
      this.listeners.addEventListener(type, listener);
    }
    abort() {
      this.record.aborted = true;
      this.listeners.dispatchEvent(new Event("abort"));
    }
    send() {
      this.record = {
        aborted: false,
        progress: (loaded, total) => {
          const event = new Event("progress") as Event & {
            lengthComputable: boolean;
            loaded: number;
            total: number;
          };
          event.lengthComputable = total > 0;
          event.loaded = loaded;
          event.total = total;
          this.upload.dispatchEvent(event);
        },
        succeed: (status) => {
          this.status = status;
          this.listeners.dispatchEvent(new Event("load"));
        },
        fail: () => this.listeners.dispatchEvent(new Event("error"))
      };
      requests.push(this.record);
    }
  }

  globalThis.XMLHttpRequest = FakeXhr as unknown as typeof XMLHttpRequest;
  return { requests, restore: () => { globalThis.XMLHttpRequest = original; } };
}

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
