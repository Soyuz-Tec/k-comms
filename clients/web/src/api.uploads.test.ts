import { afterEach, describe, expect, it, vi } from "vitest";
import {
  downloadUrl,
  isApprovedPrivateLanObjectUrl,
  sha256,
  uploadToPresignedTarget
} from "./api";

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

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
