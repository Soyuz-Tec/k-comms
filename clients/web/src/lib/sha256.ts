import {
  digestHex,
  hashBlobIncrementally,
  hashBytesIncrementally
} from "./sha256Core";
import type { Sha256WorkerResponse } from "./sha256.worker";

/**
 * `crypto.subtle.digest` resolves asynchronously and browsers run the digest
 * itself off the main thread, so the only main-thread cost of this path is the
 * decoded copy. The bound keeps that allocation predictable while covering the
 * default 25 MiB attachment cap with headroom for a raised per-tenant limit;
 * anything larger is hashed incrementally in a worker instead.
 */
const subtleCryptoBlobLimitBytes = 64 * 1024 * 1024;

export async function sha256Digest(
  input: ArrayBuffer | Uint8Array<ArrayBuffer>
): Promise<Uint8Array<ArrayBuffer>> {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  const subtle = globalThis.crypto?.subtle;

  if (subtle) {
    try {
      return new Uint8Array(await subtle.digest("SHA-256", bytes));
    } catch {
      // Some insecure browser contexts expose crypto but reject SubtleCrypto.
    }
  }

  return hashBytesIncrementally(bytes);
}

export async function sha256Hex(
  input: ArrayBuffer | Uint8Array<ArrayBuffer>
): Promise<string> {
  const digest = await sha256Digest(input);
  return digestHex(digest);
}

export async function sha256BlobHex(blob: Blob): Promise<string> {
  const subtle = globalThis.crypto?.subtle;

  if (subtle && blob.size <= subtleCryptoBlobLimitBytes) {
    try {
      const bytes = await blob.arrayBuffer();
      return digestHex(new Uint8Array(await subtle.digest("SHA-256", bytes)));
    } catch {
      // Fall through to the bounded incremental path when WebCrypto is rejected.
    }
  }

  const workerDigest = await hashBlobInWorker(blob);
  if (workerDigest !== null) return workerDigest;

  return digestHex(await hashBlobIncrementally(blob));
}

export async function sha256Base64Url(
  input: ArrayBuffer | Uint8Array<ArrayBuffer>
): Promise<string> {
  const digest = await sha256Digest(input);
  const binary = Array.from(digest, (byte) => String.fromCharCode(byte)).join("");
  return globalThis.btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/u, "");
}

/**
 * Runs the pure-JavaScript digest off the main thread. Resolves to null when no
 * worker is available — jsdom and other non-worker hosts fall back to inline
 * hashing rather than failing the upload.
 */
async function hashBlobInWorker(blob: Blob): Promise<string | null> {
  if (typeof Worker === "undefined") return null;

  let worker: Worker;
  try {
    worker = new Worker(new URL("./sha256.worker.ts", import.meta.url), {
      type: "module"
    });
  } catch {
    return null;
  }

  try {
    return await new Promise<string | null>((resolve) => {
      worker.addEventListener("message", (event: MessageEvent<Sha256WorkerResponse>) => {
        resolve(typeof event.data?.hex === "string" ? event.data.hex : null);
      });
      worker.addEventListener("error", () => resolve(null));
      worker.postMessage({ blob });
    });
  } catch {
    return null;
  } finally {
    worker.terminate();
  }
}
