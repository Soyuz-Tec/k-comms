import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/errors";
import type { Session } from "../../types";
import type { WorkspaceDiscoveryResult } from "../../types/workspaceDiscovery";
import { WorkspaceDiscovery } from "./WorkspaceDiscovery";
const mocks = vi.hoisted(() => ({ session: null as Session | null }));
vi.mock("../../app/session", () => ({ useSession: () => ({ session: mocks.session }) }));
function fixture() { return { api: { discoverWorkspace: vi.fn().mockResolvedValue({ available: false, sign_in_path: null }) }, onSelect: vi.fn() }; }
async function openAndType(domain = "team.example.org") { await userEvent.click(screen.getByText("Find workspace by domain")); await userEvent.type(screen.getByLabelText("Workspace domain"), domain); }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
beforeEach(() => { mocks.session = null; });

describe("Public workspace discovery", () => {
  it("makes only an explicit domain lookup and requires a separate safe handoff", async () => {
    const value = fixture(); value.api.discoverWorkspace.mockResolvedValue({ available: true, sign_in_path: "/sign-in?tenant_slug=example" });
    render(<WorkspaceDiscovery {...value} disabled={false} />); await openAndType("TEAM.EXAMPLE.ORG.");
    expect(value.api.discoverWorkspace).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
    expect(await screen.findByText(/You still need your own authorized account/)).toBeVisible();
    expect(value.api.discoverWorkspace).toHaveBeenCalledWith("team.example.org");
    expect(value.onSelect).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole("button", { name: "Use this workspace address" }));
    expect(value.onSelect).toHaveBeenCalledWith("/sign-in?tenant_slug=example", "example");
  });

  it("gives the same neutral unavailable response without account or enrollment inference", async () => {
    const value = fixture(); render(<WorkspaceDiscovery {...value} disabled={false} />); await openAndType();
    await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
    expect(await screen.findByText("No sign-in hint is available. Use the workspace address from your invitation or ask an administrator.")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Use this workspace address" })).not.toBeInTheDocument();
    expect(value.onSelect).not.toHaveBeenCalled();
  });

  it("does not send an email address or URL as a domain lookup", async () => {
    const value = fixture(); render(<WorkspaceDiscovery {...value} disabled={false} />); await openAndType("person@team.example.org");
    await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("not an email address or URL");
    expect(value.api.discoverWorkspace).not.toHaveBeenCalled();
  });

  it("discards a delayed hint after the user changes the exact domain", async () => {
    const pending = deferred<WorkspaceDiscoveryResult>();
    const value = fixture(); value.api.discoverWorkspace.mockReturnValueOnce(pending.promise);
    render(<WorkspaceDiscovery {...value} disabled={false} />); await openAndType();
    await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
    await userEvent.clear(screen.getByLabelText("Workspace domain"));
    await userEvent.type(screen.getByLabelText("Workspace domain"), "other.example.org");
    await act(async () => { pending.resolve({ available: true, sign_in_path: "/sign-in?tenant_slug=old-workspace" }); });
    expect(screen.queryByRole("button", { name: "Use this workspace address" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
    await waitFor(() => expect(value.api.discoverWorkspace).toHaveBeenLastCalledWith("other.example.org"));
  });

  it.each(["https://foreign.example.org/sign-in?tenant_slug=example", "//foreign.example.org", "/sign-in?tenant_slug=example&return_to=https://foreign.example.org", "/sign-in?tenant_slug=%65xample"]) (
    "refuses an untrusted discovery handoff %s", async (path) => {
      const value = fixture(); value.api.discoverWorkspace.mockResolvedValue({ available: true, sign_in_path: path });
      render(<WorkspaceDiscovery {...value} disabled={false} />); await openAndType();
      await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
      expect(await screen.findByRole("alert")).toHaveTextContent("could not be checked");
      expect(value.onSelect).not.toHaveBeenCalled();
      expect(screen.queryByRole("button", { name: "Use this workspace address" })).not.toBeInTheDocument();
    });

  it("discards an old hint when the current actor session changes", async () => {
    mocks.session = { access_token: "old-access", refresh_token: "old-refresh", token_type: "Bearer", expires_in: 900,
      tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
      user: { id: "user-1", tenant_id: "tenant-1", display_name: "Member", email: "member@example.org", role: "member", status: "active" },
      device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" } };
    const pending = deferred<WorkspaceDiscoveryResult>();
    const value = fixture(); value.api.discoverWorkspace.mockReturnValueOnce(pending.promise);
    const view = render(<WorkspaceDiscovery {...value} disabled={false} />); await openAndType();
    await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
    mocks.session = { ...mocks.session, access_token: "replacement-access" };
    view.rerender(<WorkspaceDiscovery {...value} disabled={false} />);
    await act(async () => { pending.resolve({ available: true, sign_in_path: "/sign-in?tenant_slug=old-workspace" }); });
    await userEvent.click(screen.getByText("Find workspace by domain"));
    expect(screen.getByLabelText("Workspace domain")).toHaveValue("");
    expect(screen.queryByRole("button", { name: "Use this workspace address" })).not.toBeInTheDocument();
    expect(value.onSelect).not.toHaveBeenCalled();
  });

  it("keeps discovery disabled with unavailable account transport and hides raw provider details", async () => {
    const value = fixture(); const view = render(<WorkspaceDiscovery {...value} disabled />);
    await userEvent.click(screen.getByText("Find workspace by domain"));
    expect(screen.getByLabelText("Workspace domain")).toBeDisabled();
    expect(screen.getByRole("button", { name: "Find workspace" })).toBeDisabled();
    view.rerender(<WorkspaceDiscovery {...value} disabled={false} />);
    value.api.discoverWorkspace.mockRejectedValue(new ApiError(503, "dns_unavailable", "private provider metadata"));
    await userEvent.type(screen.getByLabelText("Workspace domain"), "team.example.org");
    await userEvent.click(screen.getByRole("button", { name: "Find workspace" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("could not be checked");
    expect(screen.queryByText(/private provider metadata/)).not.toBeInTheDocument();
  });
});
