import { act, fireEvent, render, renderHook, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Session } from "../../types";
import { FederationPanel } from "./FederationPanel";
import { useFederationAuthorityGeneration } from "./useFederationAuthorityGeneration";

const session: Session = {
  access_token: "private-access-token", refresh_token: "private-refresh-token", token_type: "Bearer", expires_in: 900,
  tenant: { id: "tenant", slug: "workspace", name: "Workspace", status: "active" },
  user: { id: "user", tenant_id: "tenant", display_name: "Person", role: "owner", status: "active", version: 1, account_type: "human", access_scope: "workspace" },
  device: { id: "device", user_id: "user", name: "Browser", platform: "web" }
};
const room = { id: "room", conversation_id: "conversation", domain: "remote.example.org", residency: "Declared region", status: "active", version: 3, consent: "accepted", remote_cleanup_state: "none" } as const;
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(accept => { resolve = accept; }); return { promise, resolve }; }
function Harness({ currentSession, api }: { currentSession: Session; api: ApiClient }) {
  const generation = useFederationAuthorityGeneration(currentSession);
  return <FederationPanel api={api} conversationId="conversation" canManage authorityGeneration={generation} />;
}
function open(container: HTMLElement) { const details = container.querySelector("details")!; details.open = true; fireEvent(details, new Event("toggle")); }

describe("Federation initiating authority", () => {
  it("keeps equivalent session objects stable and generates opaque values", () => {
    const { result, rerender } = renderHook(({ current }) => useFederationAuthorityGeneration(current), { initialProps: { current: session } });
    const initial = result.current;
    rerender({ current: { ...session, tenant: { ...session.tenant }, user: { ...session.user }, device: { ...session.device } } });
    expect(result.current).toBe(initial);
    expect(initial).toMatch(/^[0-9a-f-]{36}$/);
    expect(initial).not.toContain(session.access_token);
    expect(initial).not.toContain(session.refresh_token);
  });

  it.each([
    { ...session, access_token: "new-access-token" },
    { ...session, refresh_token: "new-refresh-token" },
    { ...session, user: { ...session.user, role: "member" as const } },
    { ...session, user: { ...session.user, version: 2 } },
    { ...session, user: { ...session.user, status: "suspended" } },
    { ...session, user: { ...session.user, access_scope: "conversation_only" as const } },
    { ...session, user: { ...session.user, account_type: "guest" as const } },
    { ...session, device: { ...session.device, id: "other-device" } },
    { ...session, tenant: { ...session.tenant, status: "suspended" } },
    { ...session, device: { ...session.device, user_id: "other-user" } },
    { ...session, device: { ...session.device, revoked_at: "2026-10-05T12:00:00Z" } }
  ])("clears delayed remote plaintext after concrete initiating authority changes %#", async changed => {
    const pending = deferred<{ events: { id: string; sender: string; body: string; timestamp: number; disclosure: "plaintext_bridge" }[]; cursor: null; remote_deletion_confirmed: false }>();
    const api = { federationRoom: vi.fn().mockResolvedValue(room), federationTimeline: vi.fn().mockReturnValue(pending.promise) } as unknown as ApiClient;
    const { container, rerender } = render(<Harness currentSession={session} api={api} />);
    open(container); fireEvent.click(await screen.findByRole("button", { name: "Load remote messages" }));
    rerender(<Harness currentSession={changed} api={api} />);
    await act(async () => pending.resolve({ events: [{ id: "old", sender: "@old:remote.example.org", body: "old private remote plaintext", timestamp: 1, disclosure: "plaintext_bridge" }], cursor: null, remote_deletion_confirmed: false }));
    expect(screen.queryByText("old private remote plaintext")).not.toBeInTheDocument();
    expect(screen.queryByText("Your consent")).not.toBeInTheDocument();
    expect(container.innerHTML).not.toContain(session.access_token);
    expect(container.innerHTML).not.toContain(session.refresh_token);
  });

  it("does not download a delayed export after a same-identity credential change", async () => {
    const pending = deferred<object>();
    const api = { federationRoom: vi.fn().mockResolvedValue(room), exportFederationMetadata: vi.fn().mockReturnValue(pending.promise) } as unknown as ApiClient;
    const create = vi.spyOn(URL, "createObjectURL");
    const { container, rerender } = render(<Harness currentSession={session} api={api} />);
    open(container); fireEvent.click(await screen.findByRole("button", { name: "Download local federation metadata" }));
    await waitFor(() => expect(api.exportFederationMetadata).toHaveBeenCalled());
    rerender(<Harness currentSession={{ ...session, access_token: "new-current-token" }} api={api} />);
    await act(async () => pending.resolve({ private: "old export" }));
    expect(create).not.toHaveBeenCalled();
    create.mockRestore();
  });

  it("never applies a delayed withdrawal receipt in a new role generation", async () => {
    const pending = deferred<typeof room>();
    const api = { federationRoom: vi.fn().mockResolvedValue(room), federationConsent: vi.fn().mockReturnValue(pending.promise) } as unknown as ApiClient;
    const { container, rerender } = render(<Harness currentSession={session} api={api} />);
    open(container); fireEvent.click(await screen.findByRole("button", { name: "Withdraw my consent" }));
    await screen.findByText(/Consent withdrawal is pending/);
    expect(screen.queryByRole("button", { name: "Load remote messages" })).not.toBeInTheDocument();
    rerender(<Harness currentSession={{ ...session, user: { ...session.user, role: "member", version: 2 } }} api={api} />);
    await act(async () => pending.resolve(room));
    expect(screen.queryByText("Your consent")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Load remote messages" })).not.toBeInTheDocument();
  });
});
