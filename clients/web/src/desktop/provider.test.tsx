// @vitest-environment-options {"url":"https://comms.example.org/app/"}
import { useEffect } from "react";
import { act, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { SessionProvider, useSession } from "../app/session";
import type { ApiClient } from "../api";
import type { GuestSession, Session } from "../types";
import { initializeDesktopSessionStorage, loadDesktopSession, storeDesktopSession } from "./session";

afterEach(() => { vi.unstubAllGlobals(); Reflect.deleteProperty(window, "kCommsDesktop"); });
it("switching to a guest clears the real member provider and cancels a late member refresh generation", async () => {
  const member = { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900, tenant: { id: "tenant", name: "Fixture", slug: "fixture", status: "active" }, user: { id: "user", tenant_id: "tenant", display_name: "Fixture", role: "member", status: "active", account_type: "human" }, device: { id: "device", user_id: "user", name: "Fixture", platform: "web" } } as Session;
  const guest = { ...member, user: { ...member.user, id: "guest", account_type: "guest" }, conversation: { id: "room" }, capabilities: {} } as GuestSession;
  const replace = vi.fn(async (command: { generation: number }) => ({ generation: command.generation }));
  Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: { version: 1, getState: async () => ({ version: 1, serviceOrigin: window.location.origin, generation: 0, credentialStorage: "os-encrypted", updates: "disabled", unsigned: true, platform: "linux" }), credentials: { load: async () => ({ generation: 0, kind: "member", value: member }), replace } } });
  let completeRefresh: (response: Response) => void = () => {};
  const fetch = vi.fn<typeof globalThis.fetch>(async url => {
    if (url === "/api/v1/status") return new Response(JSON.stringify({ capabilities: { secure_account_actions: true, secure_media_actions: true } }), { headers: { "Content-Type": "application/json" } });
    if (url === "/api/v1/sessions/refresh") return new Promise(resolve => { completeRefresh = resolve; });
    throw new Error("Unexpected request");
  });
  vi.stubGlobal("fetch", fetch); await initializeDesktopSessionStorage();
  const closeOwnedMemberResources = vi.fn(); let api: ApiClient | undefined;
  function CurrentIdentity() {
    const state = useSession(); api = state.api;
    useEffect(() => state.session ? closeOwnedMemberResources : undefined, [state.session]);
    return <p>{state.session ? "Current member" : "Member cleared"}</p>;
  }
  render(<SessionProvider><CurrentIdentity /></SessionProvider>); await screen.findByText("Current member");
  const pending = api!.refreshSession(); await waitFor(() => expect(fetch).toHaveBeenCalledWith("/api/v1/sessions/refresh", expect.anything()));
  await act(async () => { storeDesktopSession("guest", guest); });
  expect(screen.getByText("Member cleared")).toBeInTheDocument(); expect(closeOwnedMemberResources).toHaveBeenCalledOnce();
  completeRefresh(new Response(JSON.stringify({ ...member, access_token: "late-member-access" }), { headers: { "Content-Type": "application/json" } }));
  await expect(pending).resolves.toBeNull(); expect(loadDesktopSession("guest")).toEqual(guest); expect(loadDesktopSession("member")).toBeNull(); expect(replace).toHaveBeenCalledOnce();
});
