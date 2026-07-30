import type { GuestSession, Session } from "../types";

export function sameMemberSessionIdentity(
  left: Session | null,
  right: Session | null
): boolean {
  if (!left || !right) return left === right;
  return left.tenant.id === right.tenant.id &&
    left.user.id === right.user.id &&
    left.device.id === right.device.id;
}

export function sameGuestSessionIdentity(
  left: GuestSession | null,
  right: GuestSession | null
): boolean {
  if (!left || !right) return left === right;
  return left.tenant.id === right.tenant.id &&
    left.user.id === right.user.id &&
    left.device.id === right.device.id &&
    left.conversation.id === right.conversation.id;
}

export function withReceivedAt<T extends Session>(session: T): T {
  return { ...session, received_at: Date.now() };
}
