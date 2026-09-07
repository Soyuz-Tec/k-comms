import type { WhiteboardElementData } from "../../types";

export interface WhiteboardOutboxEntry {
  id: string;
  baseSequence: number;
  elements: WhiteboardElementData[];
  createdAt: string;
}

const DATABASE_NAME = "k-comms-whiteboard-v1";
const STORE_NAME = "operations";
const FALLBACK_PREFIX = "k-comms.whiteboard-outbox.v1:";
const ALLOWED_TYPES = new Set([
  "rectangle", "diamond", "ellipse", "line", "arrow", "freedraw", "text", "frame"
]);

// Each immutable operation has its own record. A second tab can recover or
// acknowledge the same ID without overwriting another tab's unsent edits.
export async function loadWhiteboardOutbox(key: string): Promise<WhiteboardOutboxEntry[]> {
  const entries = new Map<string, WhiteboardOutboxEntry>();
  try {
    const stored = await transaction("readonly", (store) => store.index("scope").getAll(key));
    for (const record of stored) {
      const entry = normalizeEntry(record.entry);
      if (entry) entries.set(entry.id, entry);
    }
  } catch {
    // The fallback also covers policies which deny IndexedDB.
  }
  try {
    const prefix = fallbackPrefix(key);
    for (let index = 0; index < localStorage.length; index += 1) {
      const storageKey = localStorage.key(index);
      if (!storageKey?.startsWith(prefix)) continue;
      try {
        const entry = normalizeEntry(JSON.parse(localStorage.getItem(storageKey) || "null"));
        if (entry) entries.set(entry.id, entry);
      } catch { /* Ignore only the damaged entry, not the remaining outbox. */ }
    }
  } catch { /* Browser storage can be unavailable. */ }
  return [...entries.values()].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
}

/** Returns false if neither browser store can retain the batch. */
export async function saveWhiteboardOutbox(
  key: string,
  entries: readonly WhiteboardOutboxEntry[]
): Promise<boolean> {
  // A synchronous fallback also protects pagehide, when IndexedDB completion
  // is not guaranteed. Successful IndexedDB writes remove the temporary copy.
  let fallbackSaved = true;
  for (const entry of entries) {
    try {
      localStorage.setItem(fallbackPrefix(key) + entry.id, JSON.stringify(entry));
    } catch { fallbackSaved = false; }
  }
  try {
    await transaction("readwrite", (store) => {
      for (const entry of entries) store.put({ key: key + "\0" + entry.id, scope: key, entry });
    });
    for (const entry of entries) {
      try { localStorage.removeItem(fallbackPrefix(key) + entry.id); } catch { /* best effort */ }
    }
    return true;
  } catch {
    return fallbackSaved;
  }
}

export async function clearWhiteboardOutbox(key: string, ids: readonly string[]): Promise<void> {
  // Remove only acknowledged/invalidated IDs, never another tab's snapshot.
  for (const id of ids) {
    try { localStorage.removeItem(fallbackPrefix(key) + id); } catch { /* best effort */ }
  }
  try {
    await transaction("readwrite", (store) => {
      for (const id of ids) store.delete(key + "\0" + id);
    });
  } catch {
    // Replaying an already acknowledged ID is safe under server idempotency.
  }
}

function fallbackPrefix(key: string): string {
  return FALLBACK_PREFIX + encodeURIComponent(key) + ":";
}

function normalizeEntry(value: unknown): WhiteboardOutboxEntry | null {
  if (!value || typeof value !== "object") return null;
  const entry = value as WhiteboardOutboxEntry;
  if (
    typeof entry.id !== "string" || entry.id.length < 8 || entry.id.length > 128 ||
    !Number.isSafeInteger(entry.baseSequence) || entry.baseSequence < 0 ||
    typeof entry.createdAt !== "string" || !Number.isFinite(Date.parse(entry.createdAt)) ||
    !Array.isArray(entry.elements) || entry.elements.length === 0 || entry.elements.length > 50 ||
    !entry.elements.every((element) =>
      element && typeof element.id === "string" && element.id.length >= 8 &&
      ALLOWED_TYPES.has(element.type) && Number.isFinite(element.version) &&
      Number.isFinite(element.versionNonce) && !element.link && !element.customData
    )
  ) return null;
  return entry;
}

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") {
      reject(new Error("Browser recovery storage is unavailable"));
      return;
    }
    const request = indexedDB.open(DATABASE_NAME, 1);
    let finished = false;
    const timer = window.setTimeout(() => {
      finished = true;
      reject(new Error("Browser recovery storage did not respond"));
    }, 1_500);
    request.onerror = () => {
      window.clearTimeout(timer);
      finished = true;
      reject(request.error);
    };
    request.onsuccess = () => {
      window.clearTimeout(timer);
      if (finished) request.result.close();
      else resolve(request.result);
    };
    request.onupgradeneeded = () => {
      const database = request.result;
      const store = database.createObjectStore(STORE_NAME, { keyPath: "key" });
      store.createIndex("scope", "scope");
    };
  });
}

async function transaction<T>(
  mode: IDBTransactionMode,
  action: (store: IDBObjectStore) => IDBRequest<T> | void
): Promise<T> {
  const database = await openDatabase();
  try {
    return await new Promise<T>((resolve, reject) => {
      const tx = database.transaction(STORE_NAME, mode);
      const request = action(tx.objectStore(STORE_NAME));
      tx.oncomplete = () => resolve(request?.result as T);
      tx.onerror = tx.onabort = () => reject(tx.error);
    });
  } finally {
    database.close();
  }
}
