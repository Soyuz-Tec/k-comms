import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { GuestSession, Session } from "../types";
import type { DesktopBridge } from "./session";

const member = { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900, tenant: { id: "tenant", name: "Fixture", slug: "fixture", status: "active" }, user: { id: "user", tenant_id: "tenant", display_name: "Fixture", role: "owner", status: "active", account_type: "human" }, device: { id: "device", user_id: "user", name: "Fixture", platform: "web" } } as Session;
const guest = { ...member, user: { ...member.user, account_type: "guest" }, conversation: { id: "room" }, capabilities: {} } as GuestSession;
const current = { tenant: member.tenant, user: { ...member.user, role: "member" }, device: member.device, capabilities: {} };
function bridgeFixture(value: Session | GuestSession, kind: "member" | "guest" = "member") {
  const bridge = { version: 1 as const, getState: vi.fn<DesktopBridge["getState"]>(async () => ({ version: 1, serviceOrigin: "https://comms.example.org", generation: 0, credentialStorage: "os-encrypted", updates: "disabled", unsigned: true, platform: "linux" })), credentials: { load: vi.fn<DesktopBridge["credentials"]["load"]>(async () => ({ generation: 0, kind, value })), replace: vi.fn<DesktopBridge["credentials"]["replace"]>(async command => ({ generation: command.generation })) } };
  const storage = { getItem: vi.fn(), setItem: vi.fn(), removeItem: vi.fn() };
  vi.stubGlobal("window", { kCommsDesktop: bridge, location: { origin: "https://comms.example.org", protocol: "https:" }, sessionStorage: storage, localStorage: storage, dispatchEvent: vi.fn() });
  return { bridge, storage };
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
beforeEach(() => vi.resetModules());
afterEach(() => vi.unstubAllGlobals());

it("confirms current member ownership through the actual API and waits for encrypted current-profile persistence", async () => {
  const { bridge, storage } = bridgeFixture(member); const fetch = vi.fn<typeof globalThis.fetch>(async () => json(current)); vi.stubGlobal("fetch", fetch);
  const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage();
  let persist: (value: { generation: number }) => void = () => {}; bridge.credentials.replace.mockImplementationOnce(() => new Promise(resolve => { persist = resolve; }));
  const { verifyDesktopRestoredSession } = await import("./restore"); let mounted = false;
  const pending = verifyDesktopRestoredSession().then(() => { mounted = true; }); await vi.waitFor(() => expect(bridge.credentials.replace).toHaveBeenCalled());
  expect(mounted).toBe(false); expect(fetch.mock.calls[0]?.[0]).toBe("/api/v1/me"); expect(desktop.loadDesktopSession("member")?.user.role).toBe("member");
  persist({ generation: 1 }); await pending; expect(mounted).toBe(true); expect(storage.getItem).not.toHaveBeenCalled(); expect(storage.setItem).not.toHaveBeenCalled();
});
it("uses the existing refresh flow when the saved member access token expires", async () => {
  bridgeFixture(member); const refreshed = { ...member, access_token: "current-access", refresh_token: "current-refresh" };
  const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValueOnce(json({ error: { code: "expired" } }, 401)).mockResolvedValueOnce(json(refreshed)).mockResolvedValueOnce(json(current)); vi.stubGlobal("fetch", fetch);
  const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage(); await (await import("./restore")).verifyDesktopRestoredSession();
  expect(fetch.mock.calls.map(call => call[0])).toEqual(["/api/v1/me", "/api/v1/sessions/refresh", "/api/v1/me"]);
  expect(new Headers(fetch.mock.calls[2]?.[1]?.headers).get("Authorization")).toBe("Bearer current-access"); expect(desktop.loadDesktopSession("member")?.refresh_token).toBe("current-refresh");
});
it("clears a durably revoked member and returns to sign in without cached privilege", async () => {
  const { bridge } = bridgeFixture(member); vi.stubGlobal("fetch", vi.fn<typeof globalThis.fetch>(async () => json({ error: { code: "session_revoked" } }, 401)));
  const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage(); await (await import("./restore")).verifyDesktopRestoredSession();
  expect(desktop.loadDesktopSession("member")).toBeNull(); expect(bridge.credentials.replace).toHaveBeenLastCalledWith(expect.objectContaining({ kind: null, value: null }));
});
it("confirms guest admission through the existing room-scoped API", async () => {
  bridgeFixture(guest, "guest"); const fetch = vi.fn<typeof globalThis.fetch>(async () => json({ data: { id: "room" } })); vi.stubGlobal("fetch", fetch);
  const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage(); await (await import("./restore")).verifyDesktopRestoredSession();
  expect(fetch.mock.calls[0]?.[0]).toBe("/api/v1/guest/conversation"); expect(desktop.loadDesktopSession("guest")).toEqual(guest); expect(desktop.loadDesktopSession("member")).toBeNull();
});
it("refuses a guest restore whose current room does not match its saved admission", async () => {
  bridgeFixture(guest, "guest"); vi.stubGlobal("fetch", vi.fn<typeof globalThis.fetch>(async () => json({ data: { id: "other-room" } })));
  const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage(); await (await import("./restore")).verifyDesktopRestoredSession(); expect(desktop.loadDesktopSession("guest")).toBeNull();
});
it("service failure blocks this launch and clears cached credentials rather than trusting the saved DTO", async () => {
  bridgeFixture(member); vi.stubGlobal("fetch", vi.fn<typeof globalThis.fetch>(async () => json({ error: { code: "unavailable" } }, 503)));
  const desktop = await import("./session"); await desktop.initializeDesktopSessionStorage(); await expect((await import("./restore")).verifyDesktopRestoredSession()).rejects.toThrow("could not confirm"); expect(desktop.loadDesktopSession("member")).toBeNull();
});
it("does not add a restore request to the existing browser client", async () => {
  vi.stubGlobal("window", {}); const fetch = vi.fn(); vi.stubGlobal("fetch", fetch); await (await import("./restore")).verifyDesktopRestoredSession(); expect(fetch).not.toHaveBeenCalled();
});
