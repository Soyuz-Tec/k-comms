import type { UploadDescriptor } from "../types";
import { sha256BlobHex } from "../lib/sha256";

export function attachmentFilename(contentDisposition: string | null): string {
  const fallback = "k-comms-audit.csv";
  if (!contentDisposition) return fallback;

  const encoded = contentDisposition.match(/filename\*=UTF-8''([^;]+)/i)?.[1];
  const basic = contentDisposition.match(/filename="?([^";]+)"?/i)?.[1];
  try {
    const candidate = encoded ? decodeURIComponent(encoded) : basic;
    return candidate && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.csv$/i.test(candidate)
      ? candidate
      : fallback;
  } catch {
    return fallback;
  }
}

export function nonNegativeHeaderInteger(value: string | null): number {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
}

export async function sha256(file: File): Promise<string> {
  return sha256BlobHex(file);
}

/** Hashes a generated Blob, which unlike an upload is not a File. */
export async function sha256Blob(blob: Blob): Promise<string> {
  return sha256BlobHex(blob);
}

/**
 * Uploads through XMLHttpRequest rather than fetch because fetch reports no
 * progress for a request body: the browser exposes upload progress only through
 * XHR's upload events. Without them the queue can show that an upload is
 * running but never how far along it is, which is indistinguishable from a
 * stall on a large file over a slow link.
 */
export async function uploadToPresignedTarget(
  descriptor: UploadDescriptor,
  file: File | Blob,
  signal?: AbortSignal,
  onProgress?: (fraction: number) => void
): Promise<void> {
  const url = validatedPresignedUrl(descriptor);

  let body: XMLHttpRequestBodyInit = file;
  const headers = new Headers(descriptor.headers);
  if (descriptor.fields && Object.keys(descriptor.fields).length > 0) {
    const form = new FormData();
    Object.entries(descriptor.fields).forEach(([key, value]) => form.append(key, value));
    form.append("file", file);
    body = form;
  } else if (!headers.has("content-type")) {
    headers.set("content-type", attachmentContentType(file));
  }

  const method = descriptor.method || (descriptor.fields ? "POST" : "PUT");

  await new Promise<void>((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError());
      return;
    }

    const request = new XMLHttpRequest();
    request.open(method, url, true);
    headers.forEach((value, name) => request.setRequestHeader(name, value));

    const detach = () => signal?.removeEventListener("abort", onAbort);
    const onAbort = () => request.abort();
    signal?.addEventListener("abort", onAbort, { once: true });

    request.upload.addEventListener("progress", (event) => {
      // Without a total the browser cannot report a fraction, so the caller
      // keeps its indeterminate state rather than being fed a fabricated one.
      if (!onProgress || !event.lengthComputable || event.total <= 0) return;
      onProgress(Math.min(1, event.loaded / event.total));
    });

    request.addEventListener("load", () => {
      detach();
      if (request.status >= 200 && request.status < 300) {
        onProgress?.(1);
        resolve();
        return;
      }
      reject(new Error(`Object upload failed with status ${request.status}`));
    });

    request.addEventListener("error", () => {
      detach();
      reject(new Error("Object upload failed"));
    });

    request.addEventListener("abort", () => {
      detach();
      reject(abortError());
    });

    request.send(body);
  });
}

/**
 * Mirrors the DOMException fetch raises on abort so existing callers, which
 * detect cancellation by name, keep working unchanged.
 */
function abortError(): Error {
  if (typeof DOMException === "function") return new DOMException("Aborted", "AbortError");
  const error = new Error("Aborted");
  error.name = "AbortError";
  return error;
}

export function downloadUrl(descriptor?: UploadDescriptor): string | null {
  if (!descriptor) return null;
  try {
    return validatedPresignedUrl(descriptor);
  } catch {
    return null;
  }
}

function validatedPresignedUrl(descriptor: UploadDescriptor): string {
  const raw = descriptor.url || descriptor.upload_url || descriptor.href;
  if (!raw) throw new Error("The object store did not return a URL");
  if (!descriptor.approved_origin) throw new Error("The object store did not identify an approved origin");

  const target = new URL(raw, window.location.origin);
  const approved = new URL(descriptor.approved_origin, window.location.origin);
  if (target.username || target.password) throw new Error("Object-store URLs cannot contain credentials");
  if (target.origin !== approved.origin) throw new Error("The object-store URL did not match its approved origin");

  const localDevelopment =
    target.protocol === "http:" &&
    ["localhost", "127.0.0.1", "[::1]"].includes(target.hostname) &&
    ["localhost", "127.0.0.1", "[::1]"].includes(approved.hostname);
  const privateLanEvaluation = isApprovedPrivateLanObjectUrl(
    target,
    approved,
    new URL(window.location.href)
  );
  if (target.protocol !== "https:" && !localDevelopment && !privateLanEvaluation) {
    throw new Error("Object-store URLs must use HTTPS");
  }
  return target.toString();
}

export function isApprovedPrivateLanObjectUrl(
  target: URL,
  approved: URL,
  page: URL
): boolean {
  return (
    target.protocol === "http:" &&
    approved.protocol === "http:" &&
    page.protocol === "http:" &&
    target.origin === approved.origin &&
    target.hostname === approved.hostname &&
    target.hostname === page.hostname &&
    isCanonicalRfc1918Host(target.hostname)
  );
}

function isCanonicalRfc1918Host(hostname: string): boolean {
  const parts = hostname.split(".");
  if (parts.length !== 4) return false;
  if (parts.some((part) => !/^(0|[1-9][0-9]{0,2})$/.test(part))) return false;
  const octets = parts.map(Number);
  if (octets.some((octet) => octet > 255)) return false;
  const [first, second] = octets as [number, number, number, number];
  return (
    first === 10 ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168)
  );
}

export function attachmentContentType(file: File | Blob): string {
  if (file.type) return file.type;
  // A generated Blob carries no name to infer from, and its descriptor already
  // signs an explicit content type, so extension sniffing is File-only.
  if (!(file instanceof File)) return "application/octet-stream";
  const extension = file.name.toLowerCase().split(".").pop();
  const known: Record<string, string> = {
    csv: "text/csv",
    gif: "image/gif",
    jpeg: "image/jpeg",
    jpg: "image/jpeg",
    json: "application/json",
    md: "text/markdown",
    pdf: "application/pdf",
    png: "image/png",
    svg: "image/svg+xml",
    txt: "text/plain",
    webp: "image/webp",
    zip: "application/zip"
  };
  return (extension && known[extension]) || "application/octet-stream";
}
