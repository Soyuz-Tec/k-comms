import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { GuestSession, Session } from "../types";
import type { DesktopBridge } from "./session";
const session = { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900, tenant: { id: "tenant", name: "Fixture", slug: "fixture", status: "active" }, user: { id: "user", tenant_id: "tenant", display_name: "Fixture", role: "member", status: "active", account_type: "human" }, device: { id: "device", user_id: "user", name: "Fixture", platform: "web" } } as Session;
const origin = "https://comms.example.org";
function setupBridge() {
  const listeners = new Map<string, () => void>();
  const storage = { getItem: vi.fn(() => null), setItem: vi.fn(), removeItem: vi.fn() };
  const bridge = { version: 1 as const, getState: vi.fn<DesktopBridge["getState"]>(async () => ({ version: 1, serviceOrigin: origin, generation: 0, credentialStorage: "os-encrypted", updates: "disabled", unsigned: true, platform: "linux" })), credentials: { load: vi.fn<DesktopBridge["credentials"]["load"]>(async () => ({ generation: 0, kind: "member", value: session })), replace: vi.fn<DesktopBridge["credentials"]["replace"]>(async command => ({ generation: command.generation })) } };
  vi.stubGlobal("window", { kCommsDesktop: bridge, location: { origin, protocol: "https:" }, sessionStorage: storage, localStorage: storage, addEventListener: (event: string, cb: () => void) => listeners.set(event, cb), removeEventListener: (event: string) => listeners.delete(event), dispatchEvent: (event: Event) => { listeners.get(event.type)?.(); return true; } });
  return { bridge, storage };
}
beforeEach(() => vi.resetModules());
afterEach(() => vi.unstubAllGlobals());
describe("desktop current-session storage", () => {
  it("hydrates encrypted credentials once without reading or writing browser credentials", async () => {
    const { storage } = setupBridge(); const api = await import("../api/sessionStorage"); const desktop = await import("./session");
    expect(api.loadStoredSession()).toBeNull(); await desktop.initializeDesktopSessionStorage(); expect(api.loadStoredSession()).toEqual(session);
    api.storeSession({ ...session, access_token: "refreshed" }); expect(storage.setItem).not.toHaveBeenCalled(); expect(storage.getItem).not.toHaveBeenCalled();
  });
  it("logout reaches the native generation immediately while an earlier write is pending", async () => {
    const { bridge } = setupBridge(); const desktop = await import("./session"); const api = await import("../api/sessionStorage"); await desktop.initializeDesktopSessionStorage();
    let complete: (value: { generation: number }) => void = () => {};
    bridge.credentials.replace.mockImplementationOnce(() => new Promise(resolve => { complete = resolve; }));
    api.storeSession(session); api.storeSession(null);
    expect(bridge.credentials.replace).toHaveBeenNthCalledWith(1, { generation: 1, kind: "member", value: session });
    expect(bridge.credentials.replace).toHaveBeenNthCalledWith(2, { generation: 2, kind: null, value: null });
    complete({ generation: 1 }); await Promise.resolve(); expect(api.loadStoredSession()).toBeNull();
  });
  it("late rejected writes cannot clear a newer switched session", async () => {
    const { bridge } = setupBridge(); const desktop = await import("./session"); const api = await import("../api/sessionStorage"); await desktop.initializeDesktopSessionStorage();
    let reject: (reason: Error) => void = () => {};
    bridge.credentials.replace.mockImplementationOnce(() => new Promise((_resolve, fail) => { reject = fail; }));
    api.storeSession(session); const next = { ...session, user: { ...session.user, id: "other" } }; api.storeSession(next); reject(new Error("old write failed")); await Promise.resolve(); await Promise.resolve(); expect(api.loadStoredSession()).toEqual(next);
  });
  it("unavailable OS storage blocks bootstrap and never restores legacy plaintext", async () => {
    const { bridge, storage } = setupBridge(); bridge.getState.mockResolvedValueOnce({ version: 1, serviceOrigin: origin, generation: 10, credentialStorage: "unavailable", updates: "disabled", unsigned: true, platform: "linux" });
    const desktop = await import("./session"); await expect(desktop.initializeDesktopSessionStorage()).rejects.toThrow("operating-system");
    expect(bridge.credentials.load).not.toHaveBeenCalled(); expect(storage.getItem).not.toHaveBeenCalled(); expect(storage.setItem).not.toHaveBeenCalled(); expect(desktop.loadDesktopSession("member")).toBeNull();
    expect(bridge.credentials.replace).toHaveBeenCalledWith({ generation: 11, kind: null, value: null });
  });
  it("storage failure clears both member and guest caches and signals the blocking boundary", async () => {
    const { bridge } = setupBridge(); const desktop = await import("./session"); const api = await import("../api/sessionStorage"); await desktop.initializeDesktopSessionStorage();
    const listener = vi.fn(); desktop.subscribeDesktopStorageFailure(listener); bridge.credentials.replace.mockRejectedValueOnce(new Error("OS unavailable")); api.storeSession(session); await Promise.resolve(); await Promise.resolve();
    expect(listener).toHaveBeenCalled(); expect(api.loadStoredSession()).toBeNull(); expect(api.loadStoredGuestSession()).toBeNull(); expect(desktop.desktopStorageFailed()).toBe(true);
  });
  it("member bootstrap strips its noncredential conversation before native persistence", async () => {
    const { bridge } = setupBridge(); const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage();
    desktop.storeDesktopSession("member", { ...session, conversation: { id: "bootstrap-room" } } as Session);
    expect(bridge.credentials.replace).toHaveBeenCalledWith({ generation: 1, kind: "member", value: session });
  });
  it("guest conversion keeps one exclusive current identity and no legacy browser storage", async () => {
    const { bridge, storage } = setupBridge(); const guest = { ...session, user: { ...session.user, account_type: "guest" }, conversation: { id: "room" }, capabilities: {} } as GuestSession;
    bridge.credentials.load.mockResolvedValueOnce({ generation: 0, kind: "guest", value: guest });
    const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage(); expect(desktop.loadDesktopSession("member")).toBeNull();
    desktop.storeDesktopSession("member", null); expect(desktop.loadDesktopSession("guest")).toEqual(guest); expect(bridge.credentials.replace).not.toHaveBeenCalled();
    desktop.storeDesktopSession("member", session); expect(desktop.loadDesktopSession("guest")).toBeNull(); expect(desktop.loadDesktopSession("member")).toEqual(session); expect(storage.setItem).not.toHaveBeenCalled();
    desktop.storeDesktopSession("guest", null); expect(desktop.loadDesktopSession("member")).toEqual(session);
  });
});
