import type { GuestSession, Session } from "../types";

const sessionKey = "k-comms.session.v1";
const guestSessionKey = "k-comms.guest-session.v1";

export function loadStoredSession(): Session | null {
  try {
    const value = window.sessionStorage.getItem(sessionKey);
    return value ? (JSON.parse(value) as Session) : null;
  } catch {
    window.sessionStorage.removeItem(sessionKey);
    return null;
  }
}

export function storeSession(session: Session | null): void {
  if (session) {
    window.sessionStorage.setItem(sessionKey, JSON.stringify(session));
  } else {
    window.sessionStorage.removeItem(sessionKey);
  }
}

export function loadStoredGuestSession(): GuestSession | null {
  try {
    const value = window.sessionStorage.getItem(guestSessionKey);
    if (!value) return null;
    const session = JSON.parse(value) as GuestSession;
    if (
      !session.access_token ||
      !session.refresh_token ||
      session.user?.account_type !== "guest" ||
      !session.conversation?.id
    ) {
      throw new Error("Invalid guest session");
    }
    return session;
  } catch {
    window.sessionStorage.removeItem(guestSessionKey);
    return null;
  }
}

export function storeGuestSession(session: GuestSession | null): void {
  if (session) {
    window.sessionStorage.setItem(guestSessionKey, JSON.stringify(session));
  } else {
    window.sessionStorage.removeItem(guestSessionKey);
  }
}
