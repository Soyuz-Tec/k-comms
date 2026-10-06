const legacyPrefix = "k-comms.draft.v1.";
const prefix = "k-comms.draft.v2.";
// Only drafts whose latest write failed need a tab-lifetime fallback. Empty
// values are tombstones so an old persisted draft cannot reappear after send.
const sessionDrafts = new Map<string, string>();
const writtenDrafts = new Set<string>();
const draftListeners = new Set<() => void>();
let draftRevision = 0;
export function subscribeDrafts(listener: () => void): () => void {
  draftListeners.add(listener);
  const changed = () => { draftRevision += 1; listener(); };
  window.addEventListener("storage", changed);
  return () => { draftListeners.delete(listener); window.removeEventListener("storage", changed); };
}
export function draftSnapshot(): number { return draftRevision; }
/** A local clear takes precedence over an older synchronized preview. */
export function localDraftPreview(tenantId: string, userId: string, conversationId: string): string | null {
  const key = draftKey(tenantId, userId, conversationId);
  const body = load(key);
  return body || writtenDrafts.has(key) ? body : null;
}
export type DraftPersistence = "saved" | "session";

function scope(tenantId: string, userId: string): string {
  return `${prefix}${encodeURIComponent(tenantId)}.${encodeURIComponent(userId)}.`;
}

export function draftKey(tenantId: string, userId: string, conversationId: string): string {
  return `${scope(tenantId, userId)}${encodeURIComponent(conversationId)}`;
}

export function threadDraftKey(
  tenantId: string,
  userId: string,
  conversationId: string,
  threadRootMessageId: string
): string {
  return `${scope(tenantId, userId)}thread.${encodeURIComponent(conversationId)}.${encodeURIComponent(threadRootMessageId)}`;
}

export function loadDraft(tenantId: string, userId: string, conversationId: string): string {
  return load(draftKey(tenantId, userId, conversationId));
}

export function loadThreadDraft(
  tenantId: string,
  userId: string,
  conversationId: string,
  threadRootMessageId: string
): string {
  return load(threadDraftKey(tenantId, userId, conversationId, threadRootMessageId));
}

function load(key: string): string {
  if (sessionDrafts.has(key)) return sessionDrafts.get(key)!;
  try {
    return window.localStorage.getItem(key) || "";
  } catch {
    return "";
  }
}

export function storeDraft(
  tenantId: string,
  userId: string,
  conversationId: string,
  value: string
): DraftPersistence {
  return store(draftKey(tenantId, userId, conversationId), value);
}

export function storeThreadDraft(
  tenantId: string,
  userId: string,
  conversationId: string,
  threadRootMessageId: string,
  value: string
): DraftPersistence {
  return store(threadDraftKey(tenantId, userId, conversationId, threadRootMessageId), value);
}

function store(key: string, value: string): DraftPersistence {
  const changed = load(key) !== value || !writtenDrafts.has(key);
  writtenDrafts.add(key);
  try {
    if (value) window.localStorage.setItem(key, value);
    else window.localStorage.removeItem(key);
    sessionDrafts.delete(key);
    return "saved";
  } catch {
    sessionDrafts.set(key, value);
    return "session";
  } finally {
    if (changed) { draftRevision += 1; draftListeners.forEach(listener => listener()); }
  }
}

export function clearDrafts(tenantId: string, userId: string): void {
  const scopedPrefix = scope(tenantId, userId);
  for (const key of writtenDrafts) if (key.startsWith(scopedPrefix)) writtenDrafts.delete(key);
  for (const key of sessionDrafts.keys()) {
    if (key.startsWith(scopedPrefix)) sessionDrafts.delete(key);
  }
  try {
    const removals: string[] = [];
    for (let index = 0; index < window.localStorage.length; index += 1) {
      const key = window.localStorage.key(index);
      if (key && (key.startsWith(scopedPrefix) || key.startsWith(legacyPrefix))) removals.push(key);
    }
    removals.forEach((key) => window.localStorage.removeItem(key));
  } catch {
    // A failed privacy cleanup must not prevent local sign-out.
  }
}
