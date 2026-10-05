import { ApiClient, ApiError, GuestApiClient } from "../api";
import { isDesktopClient, loadDesktopSession, storeDesktopSession, settleDesktopCredentials } from "./session";

/** A saved bearer envelope is storage, never proof of current admission. */
export async function verifyDesktopRestoredSession(): Promise<void> {
  if (!isDesktopClient()) return;
  const member = loadDesktopSession("member");
  const guest = loadDesktopSession("guest");
  if (!member && !guest) return;
  try {
    if (member) {
      const api = new ApiClient("", member, value => storeDesktopSession("member", value));
      const current = await api.me();
      const latest = loadDesktopSession("member");
      if (!latest || current.user.id !== member.user.id || current.tenant.id !== member.tenant.id || current.device.id !== member.device.id || current.user.status !== "active" || current.tenant.status !== "active" || current.device.revoked_at || !["human", undefined].includes(current.user.account_type)) throw new ApiError(403, "desktop_restore_denied", "The saved account is no longer available.");
      storeDesktopSession("member", { ...latest, user: current.user, tenant: current.tenant, device: current.device });
    } else if (guest) {
      const api = new GuestApiClient("", guest, value => storeDesktopSession("guest", value));
      const room = await api.conversation();
      if (!loadDesktopSession("guest") || room.id !== guest.conversation.id) throw new ApiError(403, "desktop_restore_denied", "The saved guest admission has ended.");
    }
    await settleDesktopCredentials();
  } catch (error) {
    storeDesktopSession(member ? "member" : "guest", null);
    await settleDesktopCredentials();
    // Definitive owner denial returns to sign in. A service outage blocks this
    // launch rather than showing cached privileged UI or allowing capture.
    if (error instanceof ApiError && [400, 401, 403, 404, 410].includes(error.status)) return;
    throw new Error("The authorized service could not confirm the saved desktop session. Reopen the client when it is available.", { cause: error });
  }
}
