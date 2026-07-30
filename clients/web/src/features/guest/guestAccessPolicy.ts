import { ApiError } from "../../api";
import { errorText } from "../../lib/format";
import type { GuestSession, Session } from "../../types";
import {
  instantRoomJoinIdempotencyKey,
  rotateInstantRoomJoinIdempotencyKey
} from "../instant-room/idempotency";

export async function joinInstantRoomWithReplayRecovery<T>(
  token: string,
  mode: "account" | "guest",
  join: (idempotencyKey: string) => Promise<T>
): Promise<T> {
  const idempotencyKey = await instantRoomJoinIdempotencyKey(token, mode);
  try {
    return await join(idempotencyKey);
  } catch (reason: unknown) {
    if (isExpiredReplay(reason)) {
      return join(await rotateInstantRoomJoinIdempotencyKey(token, mode));
    }
    if (isTransientJoinFailure(reason)) {
      await waitForRetry();
      try {
        return await join(idempotencyKey);
      } catch (retryReason: unknown) {
        if (isExpiredReplay(retryReason)) {
          return join(await rotateInstantRoomJoinIdempotencyKey(token, mode));
        }
        throw retryReason;
      }
    }
    throw reason;
  }
}

function isExpiredReplay(reason: unknown): boolean {
  return (
    reason instanceof ApiError &&
    reason.status === 409 &&
    reason.code === "idempotency_replay_expired"
  );
}

function isTransientJoinFailure(reason: unknown): boolean {
  return (
    reason instanceof TypeError ||
    (reason instanceof ApiError && reason.status >= 500)
  );
}

export function isRetryableGuestLinkFailure(reason: unknown): boolean {
  return (
    reason instanceof TypeError ||
    (reason instanceof ApiError &&
      (reason.status === 429 || reason.status >= 500))
  );
}

export function setGuestRetryDeadline(
  reason: unknown,
  setRetryAt: (deadline: number | null) => void,
  setClock: (now: number) => void
): void {
  const retryAfter =
    reason instanceof ApiError ? reason.retryAfterSeconds : undefined;
  const now = Date.now();
  setClock(now);
  setRetryAt(retryAfter && retryAfter > 0 ? now + retryAfter * 1_000 : null);
}

function waitForRetry(): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, 350));
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

export function isDefinitiveRoomUnavailable(reason: unknown): boolean {
  return (
    reason instanceof ApiError &&
    [401, 403, 404, 410].includes(reason.status)
  );
}



export function guestLinkError(reason: unknown): string {
  if (reason instanceof ApiError) {
    if (reason.status === 426) {
      return "This action requires trusted HTTPS. Open the secure K-Comms address and try again.";
    }
    if (reason.status === 429) {
      return reason.retryAfterSeconds
        ? `Too many attempts. Try again in ${reason.retryAfterSeconds} seconds.`
        : "Too many attempts. Wait a moment, then try again.";
    }
    if (reason.status >= 500) {
      return "K-Comms is temporarily unavailable. Your link is unchanged; try again shortly.";
    }
    if (
      [404, 410, 422].includes(reason.status) ||
      /expired|revoked|unavailable|exhausted/u.test(reason.code)
    ) {
      return "This communication link is unavailable. It may have expired or been revoked. Ask the host for a new link.";
    }
  }
  const message = errorText(reason);
  return message === "Something went wrong. Please try again."
    ? "This guest link is no longer available. Ask the host for a new link."
    : message;
}
