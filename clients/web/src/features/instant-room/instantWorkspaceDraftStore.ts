import type { WhiteboardElementData } from "../../types";

const storageKey = "k-comms.instant-workspace-draft.v1";

export interface InstantWorkspaceDraftRecord {
  version: 1;
  id: string;
  displayName: string;
  roomTitle: string;
  elements: WhiteboardElementData[];
  messageClientId: string;
  whiteboardOperationId: string;
  updatedAt: string;
}

export function loadInstantWorkspaceDraft(
  fallbackDisplayName: string
): InstantWorkspaceDraftRecord {
  try {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) return newInstantWorkspaceDraft(fallbackDisplayName);
    const value = JSON.parse(raw) as Partial<InstantWorkspaceDraftRecord>;
    if (
      value.version !== 1 ||
      typeof value.id !== "string" ||
      typeof value.displayName !== "string" ||
      typeof value.roomTitle !== "string" ||
      !Array.isArray(value.elements) ||
      typeof value.messageClientId !== "string" ||
      typeof value.whiteboardOperationId !== "string"
    ) {
      return newInstantWorkspaceDraft(fallbackDisplayName);
    }
    return {
      version: 1,
      id: value.id,
      displayName: value.displayName || fallbackDisplayName,
      roomTitle: value.roomTitle,
      elements: value.elements.filter(isWhiteboardElement),
      messageClientId: value.messageClientId,
      whiteboardOperationId: value.whiteboardOperationId,
      updatedAt:
        typeof value.updatedAt === "string"
          ? value.updatedAt
          : new Date().toISOString()
    };
  } catch {
    return newInstantWorkspaceDraft(fallbackDisplayName);
  }
}

export function saveInstantWorkspaceDraft(
  draft: InstantWorkspaceDraftRecord
): void {
  try {
    window.localStorage.setItem(storageKey, JSON.stringify(draft));
  } catch {
    // The canvas remains usable when private browsing or storage pressure
    // prevents local recovery. Durable persistence starts only after sharing.
  }
}

export function clearInstantWorkspaceDraft(): void {
  try {
    window.localStorage.removeItem(storageKey);
  } catch {
    // Storage can be unavailable in hardened browser contexts.
  }
}

export function newInstantWorkspaceDraft(
  fallbackDisplayName: string
): InstantWorkspaceDraftRecord {
  return {
    version: 1,
    id: crypto.randomUUID(),
    displayName: fallbackDisplayName,
    roomTitle: "",
    elements: [],
    messageClientId: crypto.randomUUID(),
    whiteboardOperationId: crypto.randomUUID(),
    updatedAt: new Date().toISOString()
  };
}

export function defaultGuestDisplayName(): string {
  const bytes = new Uint16Array(1);
  crypto.getRandomValues(bytes);
  return `Guest ${String((((bytes[0] ?? 0) % 10_000) + 1)).padStart(4, "0")}`;
}

function isWhiteboardElement(value: unknown): value is WhiteboardElementData {
  if (!value || typeof value !== "object") return false;
  const element = value as Partial<WhiteboardElementData>;
  return (
    typeof element.id === "string" &&
    typeof element.type === "string" &&
    typeof element.version === "number" &&
    typeof element.versionNonce === "number"
  );
}
