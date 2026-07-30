import type {
  Conversation,
  DataResponse,
  GuestSession,
  InstantRoom,
  InstantRoomPreview,
  InstantRoomResult,
  ListResponse,
  Session
} from "../../types";
import { withReceivedAt } from "../sessionIdentity";

export function unwrapData<T>(payload: DataResponse<T> | T): T {
  if (payload && typeof payload === "object" && "data" in payload) {
    return (payload as DataResponse<T>).data;
  }
  return payload as T;
}

export function unwrapNullableData<T>(payload: DataResponse<T | null> | T | null): T | null {
  return payload === null ? null : unwrapData(payload);
}

export function unwrapList<T>(payload: ListResponse<T> | T[]): T[] {
  return Array.isArray(payload) ? payload : payload.data;
}

export function normalizeGuestSession(payload: unknown): GuestSession {
  const outer = readObject(payload);
  const root = readObject(unwrapUnknownData(payload));
  const authentication =
    readObject(root?.authentication) ||
    readObject(root?.auth) ||
    readObject(root?.session) ||
    root;
  const conversation = readObject(root?.conversation || authentication?.conversation);
  const capabilities = readObject(root?.capabilities || authentication?.capabilities);
  if (
    !authentication ||
    typeof authentication.access_token !== "string" ||
    typeof authentication.refresh_token !== "string" ||
    !readObject(authentication.tenant) ||
    !readObject(authentication.user) ||
    !readObject(authentication.device) ||
    !conversation ||
    !capabilities
  ) {
    throw new Error("The server did not return a complete guest session.");
  }
  return withReceivedAt({
    ...(authentication as unknown as Session),
    conversation: conversation as unknown as Conversation,
    capabilities: {
      allow_audio_calls: capabilities.allow_audio_calls === true,
      allow_video_calls: capabilities.allow_video_calls === true,
      conversion_enabled: capabilities.conversion_enabled === true,
      self_service_conversion: capabilities.self_service_conversion === true,
      email_hint:
        typeof capabilities.email_hint === "string"
          ? capabilities.email_hint
          : null
    },
    admission: readObject(root?.admission) as unknown as GuestSession["admission"],
    instant_room: normalizeInstantRoom(
      root?.room || root?.instant_room || outer?.room || outer?.instant_room,
      conversation
    ) || undefined,
    share_url: firstString(
      root?.share_url,
      outer?.share_url,
      readObject(outer?.data)?.share_url
    )
  });
}

export function normalizeInstantRoomResult(payload: unknown): InstantRoomResult {
  const outer = readObject(payload);
  const data = readObject(outer?.data);
  const root = data || outer;
  const authentication =
    readObject(root?.authentication) ||
    readObject(root?.auth) ||
    readObject(root?.session) ||
    root;
  const conversation =
    readObject(root?.conversation) ||
    readObject(authentication?.conversation) ||
    readObject(outer?.conversation);
  if (!conversation || typeof conversation.id !== "string") {
    throw new Error("The server did not return the instant-room conversation.");
  }

  const room = normalizeInstantRoom(
    root?.room || root?.instant_room || outer?.room || outer?.instant_room,
    conversation
  );
  if (!room) {
    throw new Error("The server did not return complete instant-room details.");
  }

  const shareUrl = firstString(root?.share_url, outer?.share_url);
  let guestSession: GuestSession | undefined;
  if (typeof authentication?.access_token === "string") {
    guestSession = normalizeGuestSession({
      ...outer,
      ...root,
      room,
      conversation,
      share_url: shareUrl
    });
  }

  return {
    room,
    conversation: conversation as unknown as Conversation,
    share_url: shareUrl,
    guest_session: guestSession
  };
}

export function normalizeInstantRoom(
  value: unknown,
  conversation?: Record<string, unknown> | null
): InstantRoom | null {
  const room = readObject(value);
  const id = firstString(room?.id);
  const conversationId = firstString(room?.conversation_id, conversation?.id);
  const ownerUserId = firstString(room?.owner_user_id);
  const participantLimit = nonNegativeSafeInteger(room?.participant_limit);
  const insertedAt = firstString(room?.inserted_at);
  const updatedAt = firstString(room?.updated_at);
  if (
    !id ||
    !conversationId ||
    !ownerUserId ||
    participantLimit === undefined ||
    !insertedAt ||
    !updatedAt
  ) {
    return null;
  }

  const ownerKind =
    room?.owner_kind === "registered" ? "registered" : "guest";
  const rawStatus = firstString(room?.status);
  const status =
    rawStatus === "idle" ||
    rawStatus === "expired" ||
    rawStatus === "revoked"
      ? rawStatus
      : "active";
  return {
    id,
    conversation_id: conversationId,
    owner_user_id: ownerUserId,
    owner_kind: ownerKind,
    status,
    participant_limit: participantLimit,
    idle_since: firstString(room?.idle_since) || null,
    expires_at: firstString(room?.expires_at) || null,
    inserted_at: insertedAt,
    updated_at: updatedAt
  };
}

export function normalizeInstantRoomPreview(value: unknown): InstantRoomPreview {
  const preview = readObject(value);
  const roomTitle = firstString(preview?.room_title);
  const participantLimit = nonNegativeSafeInteger(preview?.participant_limit);
  const rawStatus = firstString(preview?.status);
  if (
    !roomTitle ||
    participantLimit === undefined ||
    !["active", "idle", "expired", "revoked"].includes(rawStatus || "")
  ) {
    throw new Error("The server did not return a complete instant-room preview.");
  }
  return {
    room_title: roomTitle,
    status: rawStatus as InstantRoomPreview["status"],
    expires_at: firstString(preview?.expires_at) || null,
    participant_limit: participantLimit
  };
}

export function normalizeAccountConversion(payload: unknown): {
  session: Session;
  conversation: Conversation;
  socket_handoff?: { ticket: string; expires_in: number };
} {
  const root = readObject(unwrapUnknownData(payload));
  const authentication =
    readObject(root?.authentication) ||
    readObject(root?.auth) ||
    readObject(root?.session) ||
    root;
  const conversation = readObject(root?.conversation);
  if (
    !authentication ||
    typeof authentication.access_token !== "string" ||
    typeof authentication.refresh_token !== "string" ||
    !conversation
  ) {
    throw new Error("The server did not return a complete account session.");
  }
  const handoff = readObject(root?.socket_handoff);
  const socketHandoff =
    typeof handoff?.ticket === "string" &&
    typeof handoff.expires_in === "number" &&
    Number.isSafeInteger(handoff.expires_in) &&
    handoff.expires_in > 0
      ? {
          ticket: handoff.ticket,
          expires_in: handoff.expires_in
        }
      : undefined;
  return {
    session: withReceivedAt(authentication as unknown as Session),
    conversation: conversation as unknown as Conversation,
    socket_handoff: socketHandoff
  };
}

export function unwrapUnknownData(payload: unknown): unknown {
  const object = readObject(payload);
  return object && "data" in object ? object.data : payload;
}

export function readObject(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object"
    ? value as Record<string, unknown>
    : null;
}

export function firstString(...values: unknown[]): string | undefined {
  return values.find(
    (value): value is string => typeof value === "string" && value.length > 0
  );
}

export function nonNegativeSafeInteger(value: unknown): number | undefined {
  return typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= 0
    ? value
    : undefined;
}
