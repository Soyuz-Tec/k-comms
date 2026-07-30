import { ApiError } from "../../api";
import type { Conversation, GuestCapabilities, GuestSession, InstantRoom, Session } from "../../types";

export function asRoomSession(
  session: Session,
  conversation: Conversation,
  capabilities: GuestCapabilities,
  room?: InstantRoom,
  shareUrl?: string
): GuestSession {
  return {
    ...session,
    conversation,
    capabilities,
    instant_room: room,
    share_url: shareUrl
  };
}

export function withoutGuestConversion(session: GuestSession): GuestSession {
  return {
    ...session,
    capabilities: {
      ...session.capabilities,
      conversion_enabled: false,
      self_service_conversion: false,
      email_hint: null
    }
  };
}

export function memberSessionIdentity(session: Session): string {
  return `${session.tenant.id}:${session.user.id}:${session.device.id}`;
}

export const unavailableCallCapabilities: GuestCapabilities = {
  allow_audio_calls: false,
  allow_video_calls: false,
  conversion_enabled: false,
  self_service_conversion: false
};

export function instantRoomError(reason: unknown): {
  message: string;
  retryAfterSeconds?: number;
} {
  if (!navigator.onLine || reason instanceof TypeError) {
    return {
      message:
        "You appear to be offline. Reconnect and try again; the same room request will be resumed."
    };
  }
  if (reason instanceof ApiError) {
    if (reason.status === 426) {
      return {
        message:
          "This action requires trusted HTTPS. Open the secure K-Comms address and try again."
      };
    }
    if (reason.status === 429) {
      return {
        message: reason.retryAfterSeconds
          ? `Room creation is rate-limited. Try again in ${reason.retryAfterSeconds} seconds.`
          : "Room creation is rate-limited. Wait a moment, then try again.",
        retryAfterSeconds: reason.retryAfterSeconds
      };
    }
    if ([404, 410, 422].includes(reason.status)) {
      return {
        message:
          "This room is unavailable. It may have expired or been revoked. Start a new room."
      };
    }
    if (reason.status >= 500) {
      return {
        message:
          "K-Comms is temporarily unavailable. Your request is safe to retry."
      };
    }
  }
  return {
    message:
      reason instanceof Error
        ? reason.message
        : "K-Comms could not open the room. Try again."
  };
}
