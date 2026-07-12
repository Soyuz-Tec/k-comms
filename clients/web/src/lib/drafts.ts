const legacyPrefix = "k-comms.draft.v1.";
const prefix = "k-comms.draft.v2.";

function scope(tenantId: string, userId: string): string {
  return `${prefix}${encodeURIComponent(tenantId)}.${encodeURIComponent(userId)}.`;
}

export function draftKey(tenantId: string, userId: string, conversationId: string): string {
  return `${scope(tenantId, userId)}${encodeURIComponent(conversationId)}`;
}

export function loadDraft(tenantId: string, userId: string, conversationId: string): string {
  try {
    return window.localStorage.getItem(draftKey(tenantId, userId, conversationId)) || "";
  } catch {
    return "";
  }
}

export function storeDraft(
  tenantId: string,
  userId: string,
  conversationId: string,
  value: string
): void {
  try {
    const key = draftKey(tenantId, userId, conversationId);
    if (value) window.localStorage.setItem(key, value);
    else window.localStorage.removeItem(key);
  } catch {
    // Private browsing and storage policies may disable local persistence.
  }
}

export function clearDrafts(tenantId: string, userId: string): void {
  try {
    const scopedPrefix = scope(tenantId, userId);
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
