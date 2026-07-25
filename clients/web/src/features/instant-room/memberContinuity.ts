import type {
  Conversation,
  InstantRoom,
  Session
} from "../../types";

const storageKey = "k-comms.member-instant-room.v1";
const maximumSerializedBytes = 32 * 1024;
const joinTokenPattern = /^[A-Za-z0-9_-]{43}$/;

export interface MemberInstantRoomContinuity {
  room: InstantRoom;
  conversation: Conversation;
  share_url: string;
}

interface StoredMemberInstantRoom extends MemberInstantRoomContinuity {
  version: 1;
  tenant_id: string;
  user_id: string;
}

type ContinuityStorage = Pick<
  Storage,
  "getItem" | "setItem" | "removeItem"
>;

/**
 * Persists one bounded, tab-scoped handoff after an instant-room identity
 * upgrade. `share_url` is itself a bearer credential, so this record must
 * remain in sessionStorage: never mirror it to localStorage, logs, analytics,
 * query parameters, or a reconstructed URL.
 */
export function storeMemberInstantRoomContinuity(
  session: Session,
  continuity: MemberInstantRoomContinuity,
  storage: ContinuityStorage = window.sessionStorage
): boolean {
  const stored: StoredMemberInstantRoom = {
    version: 1,
    tenant_id: session.tenant.id,
    user_id: session.user.id,
    room: continuity.room,
    conversation: continuity.conversation,
    share_url: continuity.share_url
  };
  if (!validContinuity(stored, session)) {
    storage.removeItem(storageKey);
    return false;
  }

  const serialized = JSON.stringify(stored);
  if (new TextEncoder().encode(serialized).byteLength > maximumSerializedBytes) {
    storage.removeItem(storageKey);
    return false;
  }
  storage.setItem(storageKey, serialized);
  return true;
}

export function loadMemberInstantRoomContinuity(
  session: Session,
  storage: ContinuityStorage = window.sessionStorage
): MemberInstantRoomContinuity | null {
  try {
    const serialized = storage.getItem(storageKey);
    if (!serialized) return null;
    if (
      new TextEncoder().encode(serialized).byteLength >
      maximumSerializedBytes
    ) {
      throw new Error("Oversized instant-room continuity record");
    }
    const stored = JSON.parse(serialized) as StoredMemberInstantRoom;
    if (!validContinuity(stored, session)) {
      throw new Error("Stale instant-room continuity record");
    }
    return {
      room: stored.room,
      conversation: stored.conversation,
      share_url: stored.share_url
    };
  } catch {
    storage.removeItem(storageKey);
    return null;
  }
}

export function clearMemberInstantRoomContinuity(
  storage: Pick<Storage, "removeItem"> = window.sessionStorage
): void {
  storage.removeItem(storageKey);
}

export function capturedInstantRoomShareUrl(
  token: string,
  href = window.location.href
): string | null {
  if (!joinTokenPattern.test(token) || href.length > 4_096) return null;
  try {
    const url = new URL(href);
    const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
    if (
      !["http:", "https:"].includes(url.protocol) ||
      fragment.get("guest") !== token ||
      url.searchParams.has("token")
    ) {
      return null;
    }
    return href;
  } catch {
    return null;
  }
}

function validContinuity(
  stored: StoredMemberInstantRoom,
  session: Session
): boolean {
  if (
    stored.version !== 1 ||
    stored.tenant_id !== session.tenant.id ||
    stored.user_id !== session.user.id ||
    stored.room.conversation_id !== stored.conversation.id ||
    stored.conversation.tenant_id !== session.tenant.id ||
    ["expired", "revoked"].includes(stored.room.status) ||
    !validShareUrl(stored.share_url)
  ) {
    return false;
  }
  if (
    stored.room.expires_at &&
    Date.parse(stored.room.expires_at) <= Date.now()
  ) {
    return false;
  }
  return true;
}

function validShareUrl(value: string): boolean {
  if (typeof value !== "string" || value.length > 4_096) return false;
  try {
    const url = new URL(value);
    const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
    return (
      ["http:", "https:"].includes(url.protocol) &&
      joinTokenPattern.test(fragment.get("guest") || "") &&
      !url.searchParams.has("token")
    );
  } catch {
    return false;
  }
}
