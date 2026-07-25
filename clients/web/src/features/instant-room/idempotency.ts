import { sha256Base64Url as hashSha256Base64Url } from "../../lib/sha256";

const instantRoomVisitKey = "k-comms.instant-room.idempotency.v1";
const instantRoomJoinKey = "k-comms.instant-room.join-idempotency.v1";
const encodedKeyPattern = /^[A-Za-z0-9_-]{43}$/;

/**
 * Returns one 256-bit key for the current tab's front-door visit.
 *
 * sessionStorage is deliberately used instead of localStorage: retrying or
 * React StrictMode replay in this tab must reuse the key, while another tab
 * gets an independent room. Invalid persisted values are rotated rather than
 * sent to the API.
 */
export function instantRoomIdempotencyKey(
  storage: Pick<Storage, "getItem" | "setItem"> = window.sessionStorage
): string {
  const existing = storage.getItem(instantRoomVisitKey);
  if (existing && encodedKeyPattern.test(existing)) return existing;

  const key = newInstantRoomIdempotencyKey();
  storage.setItem(instantRoomVisitKey, key);
  return key;
}

export function newInstantRoomIdempotencyKey(): string {
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return globalThis.btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/u, "");
}

export function beginNewInstantRoomVisit(
  storage: Pick<Storage, "setItem"> = window.sessionStorage
): string {
  const key = newInstantRoomIdempotencyKey();
  storage.setItem(instantRoomVisitKey, key);
  return key;
}

export async function instantRoomJoinIdempotencyKey(
  token: string,
  mode: "account" | "guest",
  storage: Pick<Storage, "getItem" | "setItem"> = window.sessionStorage
): Promise<string> {
  const tokenDigest = await sha256Base64Url(token);
  try {
    const saved = JSON.parse(storage.getItem(instantRoomJoinKey) || "{}") as {
      token_digest?: string;
      mode?: string;
      key?: string;
    };
    if (
      saved.token_digest === tokenDigest &&
      saved.mode === mode &&
      saved.key &&
      encodedKeyPattern.test(saved.key)
    ) {
      return saved.key;
    }
  } catch {
    // Rotate corrupt state below.
  }

  const key = newInstantRoomIdempotencyKey();
  persistInstantRoomJoinKey(storage, tokenDigest, mode, key);
  return key;
}

export async function rotateInstantRoomJoinIdempotencyKey(
  token: string,
  mode: "account" | "guest",
  storage: Pick<Storage, "setItem"> = window.sessionStorage
): Promise<string> {
  const tokenDigest = await sha256Base64Url(token);
  const key = newInstantRoomIdempotencyKey();
  persistInstantRoomJoinKey(storage, tokenDigest, mode, key);
  return key;
}

function persistInstantRoomJoinKey(
  storage: Pick<Storage, "setItem">,
  tokenDigest: string,
  mode: "account" | "guest",
  key: string
) {
  storage.setItem(
    instantRoomJoinKey,
    JSON.stringify({ token_digest: tokenDigest, mode, key })
  );
}

async function sha256Base64Url(value: string): Promise<string> {
  return hashSha256Base64Url(new TextEncoder().encode(value));
}
