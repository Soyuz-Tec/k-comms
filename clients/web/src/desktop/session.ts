import { installDesktopMediaGuard, stopDesktopCapture } from "./media";
import type { GuestSession, Session } from "../types";

export type DesktopKind = "member" | "guest" | null;
interface DesktopSnapshot { generation: number; kind: DesktopKind; value: Session | GuestSession | null }
export interface DesktopBridge {
  readonly version: 1;
  getState: () => Promise<{ version: 1; serviceOrigin: string; generation: number; credentialStorage: "os-encrypted" | "unavailable"; updates: "disabled"; unsigned: true; platform: string }>;
  readonly credentials: { load: () => Promise<DesktopSnapshot>; replace: (command: DesktopSnapshot) => Promise<{ generation: number }> };
}
declare global { interface Window { readonly kCommsDesktop?: DesktopBridge } }
const failureEvent = "k-comms:desktop-storage-failed";
const identityEvent = "k-comms:desktop-identity-changed";
const blockedMessage = "Secure operating-system session storage is unavailable. Close this evaluation client, restore encrypted OS storage, and sign in again. No browser-storage fallback is used.";
export const desktopCorporateMessage = "Corporate sign in and verification require the authorized web client. This unsigned desktop evaluation has no system-browser sign-in callback.";
let snapshot: DesktopSnapshot = { generation: 0, kind: null, value: null };
let ready = false;
let failed = false;
let pendingReplacement: Promise<void> = Promise.resolve();

export function isDesktopClient(): boolean { return typeof window !== "undefined" && Boolean(window.kCommsDesktop); }
export function desktopStorageFailed(): boolean { return failed; }
export function subscribeDesktopStorageFailure(listener: () => void): () => void {
  window.addEventListener(failureEvent, listener); return () => window.removeEventListener(failureEvent, listener);
}
export function subscribeDesktopIdentityChange(listener: () => void): () => void {
  if (!isDesktopClient()) return () => {};
  window.addEventListener(identityEvent, listener); return () => window.removeEventListener(identityEvent, listener);
}
function removeLegacyCredentials() {
  for (const key of ["k-comms.session.v1", "k-comms.guest-session.v1"]) {
    try { window.sessionStorage.removeItem(key); } catch { /* Never write a fallback credential. */ }
    try { window.localStorage.removeItem(key); } catch { /* Legacy plaintext is never read. */ }
  }
}
function mediaIdentity(value = snapshot): string | null {
  return value.kind && value.value ? [value.kind, value.value.tenant.id, value.value.user.id, value.value.device.id, value.kind === "guest" ? (value.value as GuestSession).conversation?.id || "" : ""].join(":") : null;
}
function failClosed() {
  if (failed) return;
  failed = true; ready = false; stopDesktopCapture();
  snapshot = { generation: snapshot.generation + 1, kind: null, value: null };
  removeLegacyCredentials();
  try { void window.kCommsDesktop?.credentials.replace({ ...snapshot }).catch(() => undefined); } catch { /* No insecure recovery. */ }
  window.dispatchEvent(new Event(failureEvent));
}
export async function initializeDesktopSessionStorage(): Promise<void> {
  if (!isDesktopClient()) return;
  removeLegacyCredentials(); ready = false; failed = false;
  const bridge = window.kCommsDesktop!;
  try {
    if (bridge.version !== 1) throw new Error(blockedMessage);
    const state = await bridge.getState();
    if (Number.isSafeInteger(state.generation) && state.generation >= 0) snapshot.generation = Math.max(snapshot.generation, state.generation);
    if (state.version !== 1 || state.credentialStorage !== "os-encrypted" || state.serviceOrigin !== window.location.origin || window.location.protocol !== "https:" || state.updates !== "disabled" || state.unsigned !== true || !Number.isSafeInteger(state.generation) || state.generation < 0) throw new Error(blockedMessage);
    const restored = await bridge.credentials.load();
    if (failed || !Number.isSafeInteger(restored.generation) || restored.generation < state.generation || !["member", "guest", null].includes(restored.kind) || ((restored.kind === null) !== (restored.value === null))) throw new Error(blockedMessage);
    if (restored.value && (!restored.value.access_token || !restored.value.refresh_token || !restored.value.user?.id || !restored.value.tenant?.id || !restored.value.device?.id)) throw new Error(blockedMessage);
    snapshot = restored; ready = true;
    installDesktopMediaGuard(() => ready && !failed ? mediaIdentity() : null);
  } catch { failClosed(); throw new Error(blockedMessage); }
}
export function loadDesktopSession(kind: "member"): Session | null;
export function loadDesktopSession(kind: "guest"): GuestSession | null;
export function loadDesktopSession(kind: "member" | "guest"): Session | GuestSession | null {
  return ready && !failed && snapshot.kind === kind ? snapshot.value : null;
}
export function storeDesktopSession(kind: "member" | "guest", value: Session | GuestSession | null): void {
  removeLegacyCredentials();
  if (!ready || failed || !window.kCommsDesktop) { failClosed(); return; }
  // The existing member and guest providers can each clear their own empty
  // cache. A late cleanup from the other kind must not log out this identity.
  if (value === null && snapshot.kind !== null && snapshot.kind !== kind) return;
  // Bootstrap may return an additional conversation alongside the member DTO.
  // Only the actual credential contract crosses the native storage boundary.
  const stored = value ? credentialEnvelope(kind, value) : null;
  const next: DesktopSnapshot = { generation: snapshot.generation + 1, kind: value ? kind : null, value: stored };
  const identityChanged = mediaIdentity(next) !== mediaIdentity();
  if (identityChanged) stopDesktopCapture();
  snapshot = next;
  if (identityChanged) window.dispatchEvent(new Event(identityEvent));
  const generation = snapshot.generation;
  // Invoke immediately. Do not serialize behind a pending earlier write: the
  // native generation must invalidate it as soon as logout/switch occurs.
  try {
    pendingReplacement = window.kCommsDesktop.credentials.replace({ ...snapshot }).then(receipt => {
      if (failed || generation !== snapshot.generation) return;
      if (!Number.isSafeInteger(receipt.generation) || receipt.generation < generation) { failClosed(); return; }
      snapshot.generation = receipt.generation;
    }).catch(() => { if (generation === snapshot.generation) failClosed(); });
  } catch { if (generation === snapshot.generation) failClosed(); }
}
function credentialEnvelope(kind: "member" | "guest", value: Session | GuestSession): Session | GuestSession {
  const member: Session = { access_token: value.access_token, refresh_token: value.refresh_token, token_type: value.token_type, expires_in: value.expires_in, tenant: value.tenant, user: value.user, device: value.device, ...(value.received_at !== undefined ? { received_at: value.received_at } : {}) };
  if (kind === "member") return member;
  const guest = value as GuestSession;
  return { ...member, conversation: guest.conversation, capabilities: guest.capabilities, ...(guest.admission !== undefined ? { admission: guest.admission } : {}), ...(guest.instant_room !== undefined ? { instant_room: guest.instant_room } : {}), ...(guest.share_url !== undefined ? { share_url: guest.share_url } : {}) };
}
/** Bootstrap waits for the latest encrypted write before mounting the UI. */
export async function settleDesktopCredentials(): Promise<void> {
  await pendingReplacement;
  if (failed) throw new Error(blockedMessage);
}
