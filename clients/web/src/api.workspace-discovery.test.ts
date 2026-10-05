import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "./api";
import type { Session } from "./types";
const session: Session = {
  access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900, received_at: Date.now(),
  tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
  user: { id: "owner-1", tenant_id: "tenant-1", display_name: "Owner", email: "owner@example.org", role: "owner", status: "active" },
  device: { id: "device-1", user_id: "owner-1", name: "Browser", platform: "web" }
};
const response = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
afterEach(() => { vi.unstubAllGlobals(); });
describe("Workspace discovery API boundaries", () => {
  it("sends only an exact domain without member credentials even when a member session exists", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(response({ data: { available: true, sign_in_path: "/sign-in?tenant_slug=example", user_exists: true, private_metadata: "ignored" } }));
    vi.stubGlobal("fetch", fetchMock); const onSession = vi.fn(); const api = new ApiClient("https://comms.test", session, onSession);
    await expect(api.discoverWorkspace("team.example.org")).resolves.toEqual({ available: true, sign_in_path: "/sign-in?tenant_slug=example" });
    const [url, options] = fetchMock.mock.calls[0]!;
    expect(url).toBe("https://comms.test/api/v1/workspaces/discover");
    expect(options?.method).toBe("POST"); expect(options?.body).toBe(JSON.stringify({ domain: "team.example.org" }));
    expect(new Headers(options?.headers).has("Authorization")).toBe(false); expect(options?.credentials).toBe("omit");
    expect(onSession).not.toHaveBeenCalled();
  });

  it("does not refresh or clear a member session on a public discovery authentication error", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(response({ error: { code: "forbidden", detail: "unavailable" } }, 401));
    vi.stubGlobal("fetch", fetchMock); const onSession = vi.fn(); const api = new ApiClient("https://comms.test", session, onSession);
    await expect(api.discoverWorkspace("team.example.org")).rejects.toMatchObject({ status: 401 });
    expect(fetchMock).toHaveBeenCalledTimes(1); expect(onSession).not.toHaveBeenCalled();
  });

  it.each([
    { available: true, sign_in_path: "https://foreign.example.org/sign-in?tenant_slug=example" },
    { available: true, sign_in_path: "/sign-in?tenant_slug=example&email=person@example.org" },
    { available: true, sign_in_path: "/sign-in?tenant_slug=example#credential" },
    { available: false, sign_in_path: "/sign-in?tenant_slug=example" }
  ])("rejects unsafe or inconsistent public response %#", async (value) => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockResolvedValue(response({ data: value })));
    await expect(new ApiClient("https://comms.test", session, vi.fn()).discoverWorkspace("team.example.org")).rejects.toMatchObject({ status: 502, code: "invalid_workspace_discovery" });
  });
});
