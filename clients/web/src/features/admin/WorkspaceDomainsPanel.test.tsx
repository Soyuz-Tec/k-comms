import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/errors";
import { StepUpProvider } from "../../app/step-up";
import type { Session } from "../../types";
import type { WorkspaceDomainClaim } from "../../types/workspaceDiscovery";
import { WorkspaceDomainsPanel } from "./WorkspaceDomainsPanel";

const mocks = vi.hoisted(() => ({ session: null as Session | null, stepUp: vi.fn() }));
vi.mock("../../app/session", () => ({ useSession: () => ({ session: mocks.session, api: { stepUp: mocks.stepUp } }) }));
const claim: WorkspaceDomainClaim = {
  id: "claim-1", domain: "team.example.org", version: 1, status: "pending", discovery_enabled: false,
  challenge_name: "_k-comms.team.example.org.", challenge_value: "k-comms-domain=synthetic-public-challenge",
  challenge_expires_at: "2099-01-01T00:00:00Z", verified_at: null, proof_expires_at: null
};
function apiFixture(initial = [claim]) {
  return {
    workspaceDomains: vi.fn().mockResolvedValue({ data: initial, limits: { domains: 8 } }),
    createWorkspaceDomain: vi.fn().mockResolvedValue(claim),
    renewWorkspaceDomain: vi.fn().mockResolvedValue({ ...claim, version: 2 }),
    verifyWorkspaceDomain: vi.fn().mockResolvedValue({ ...claim, version: 2, status: "verified", challenge_value: null, verified_at: "2026-10-05T00:00:00Z", proof_expires_at: "2099-01-01T00:00:00Z" }),
    updateWorkspaceDomainDiscovery: vi.fn().mockResolvedValue({ ...claim, version: 2, discovery_enabled: true }),
    removeWorkspaceDomain: vi.fn().mockResolvedValue({ ...claim, version: 2, discovery_enabled: false, challenge_value: null, status: "expired" })
  };
}
function renderPanel(api = apiFixture()) {
  return { api, ...render(<StepUpProvider><WorkspaceDomainsPanel api={api} /></StepUpProvider>) };
}
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
async function openInstructions() { await userEvent.click(await screen.findByText("DNS TXT instructions for team.example.org")); }
async function chooseVerify() { await userEvent.click(await screen.findByRole("button", { name: "Verify DNS for team.example.org" })); }

beforeEach(() => {
  mocks.session = {
    access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900,
    tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
    user: { id: "owner-1", tenant_id: "tenant-1", display_name: "Owner", email: "owner@example.org", role: "owner", status: "active", account_type: "human", access_scope: "workspace", version: 1 },
    device: { id: "device-1", user_id: "owner-1", name: "Browser", platform: "web" }
  };
  mocks.stepUp.mockReset().mockResolvedValue(undefined);
});

describe("Workspace domain administration", () => {
  it("keeps compact actions associated with their domain and reviews the selected version before removing", async () => {
    const second = { ...claim, id: "claim-2", domain: "other.example.org", version: 7 };
    const api = apiFixture([claim, second]);
    api.removeWorkspaceDomain.mockResolvedValue({ ...second, version: 8, status: "expired", discovery_enabled: false, challenge_value: null });
    renderPanel(api);

    const remove = await screen.findByRole("button", { name: "Remove other.example.org" });
    expect(remove).toHaveTextContent(/^Remove$/);
    expect(screen.getByRole("button", { name: "Remove team.example.org" })).toBeVisible();
    await userEvent.click(remove);
    const dialog = screen.getByRole("alertdialog", { name: "Remove domain claim?" });
    expect(dialog).toHaveTextContent("other.example.org · Current version 7.");
    expect(api.removeWorkspaceDomain).not.toHaveBeenCalled();
    await userEvent.click(within(dialog).getByRole("button", { name: "Remove claim" }));
    await waitFor(() => expect(api.removeWorkspaceDomain).toHaveBeenCalledWith("claim-2", 7));
  });

  it("loads the current inventory after StrictMode replay and ignores the canceled request while that load is pending", async () => {
    const obsolete = deferred<{ data: WorkspaceDomainClaim[]; limits: { domains: number } }>();
    const current = deferred<{ data: WorkspaceDomainClaim[]; limits: { domains: number } }>();
    const api = apiFixture([]);
    api.workspaceDomains.mockReturnValueOnce(obsolete.promise).mockReturnValueOnce(current.promise);
    render(<StrictMode><StepUpProvider><WorkspaceDomainsPanel api={api} /></StepUpProvider></StrictMode>);

    await waitFor(() => expect(api.workspaceDomains).toHaveBeenCalledTimes(2));
    await act(async () => { obsolete.resolve({ data: [claim], limits: { domains: 8 } }); });
    expect(screen.getByRole("button", { name: "Reload domain inventory" })).toBeDisabled();
    expect(screen.queryByRole("heading", { name: claim.domain })).not.toBeInTheDocument();
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();

    const fresh = { ...claim, id: "current-claim", domain: "current.example.org", version: 7,
      challenge_name: "_k-comms.current.example.org.", challenge_value: "k-comms-domain=synthetic-current-challenge" };
    await act(async () => { current.resolve({ data: [fresh], limits: { domains: 8 } }); });
    expect(await screen.findByRole("heading", { name: fresh.domain })).toBeVisible();
    expect(screen.getByRole("button", { name: "Reload domain inventory" })).toBeEnabled();
    await userEvent.click(screen.getByText("DNS TXT instructions for current.example.org"));
    expect(screen.getByText(fresh.challenge_value)).toBeVisible();
    expect(screen.queryByRole("heading", { name: claim.domain })).not.toBeInTheDocument();
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
  });

  it("allows an explicit inventory retry after the current StrictMode load fails without restoring a canceled inventory", async () => {
    const obsolete = deferred<{ data: WorkspaceDomainClaim[]; limits: { domains: number } }>();
    const api = apiFixture([]);
    api.workspaceDomains.mockReturnValueOnce(obsolete.promise)
      .mockRejectedValueOnce(new ApiError(503, "temporarily_unavailable", "temporary failure"))
      .mockResolvedValueOnce({ data: [], limits: { domains: 8 } });
    render(<StrictMode><StepUpProvider><WorkspaceDomainsPanel api={api} /></StepUpProvider></StrictMode>);

    expect(await screen.findByRole("alert")).toHaveTextContent("Domain inventory could not be loaded.");
    expect(screen.getByRole("button", { name: "Reload domain inventory" })).toBeEnabled();
    await userEvent.click(screen.getByRole("button", { name: "Reload domain inventory" }));
    expect(await screen.findByText("0 / 8 retained domain claims.")).toBeVisible();
    expect(api.workspaceDomains).toHaveBeenCalledTimes(3);
    expect(screen.getByRole("button", { name: "Add domain claim" })).toBeEnabled();

    await act(async () => { obsolete.resolve({ data: [claim], limits: { domains: 8 } }); });
    expect(screen.queryByRole("heading", { name: claim.domain })).not.toBeInTheDocument();
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
    expect(screen.getByText("0 / 8 retained domain claims.")).toBeVisible();
  });

  it("defaults creation to discovery off and consumes verified TXT without granting access", async () => {
    const { api } = renderPanel(apiFixture([]));
    await screen.findByText("0 / 8 retained domain claims.");
    await userEvent.type(screen.getByLabelText("Domain"), "TEAM.EXAMPLE.ORG.");
    await userEvent.click(screen.getByRole("button", { name: "Add domain claim" }));
    await waitFor(() => expect(api.createWorkspaceDomain).toHaveBeenCalledWith({ domain: "team.example.org", version: 0, discovery_enabled: false }));
    await openInstructions();
    expect(screen.getByText(claim.challenge_value!)).toBeVisible();
    await chooseVerify();
    await userEvent.click(screen.getByRole("button", { name: "Verify current DNS challenge" }));
    await waitFor(() => expect(api.verifyWorkspaceDomain).toHaveBeenCalledWith("claim-1", 1));
    expect(await screen.findByText(/Status: Verified proof lease/)).toBeVisible();
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
    expect(screen.getByText("Public discovery: Disabled.")).toBeVisible();
    expect(screen.getByText(/does not enroll people/)).toBeVisible();
  });

  it("reloads stale versions while preserving the explicit intended change for reviewed retry", async () => {
    const api = apiFixture();
    api.updateWorkspaceDomainDiscovery.mockRejectedValueOnce(new ApiError(409, "stale_version", "stale"));
    api.workspaceDomains.mockResolvedValueOnce({ data: [claim], limits: { domains: 8 } }).mockResolvedValue({ data: [{ ...claim, version: 7 }], limits: { domains: 8 } });
    api.updateWorkspaceDomainDiscovery.mockResolvedValueOnce({ ...claim, version: 8, discovery_enabled: true });
    renderPanel(api);
    await userEvent.click(await screen.findByRole("button", { name: "Enable discovery for team.example.org" }));
    await userEvent.click(screen.getByRole("button", { name: "Apply discovery setting" }));
    expect(await screen.findByText(/Current version 7/)).toBeVisible();
    expect(api.updateWorkspaceDomainDiscovery).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("alertdialog")).toHaveTextContent("review it and explicitly retry");
    await userEvent.click(screen.getByRole("button", { name: "Apply discovery setting" }));
    await waitFor(() => expect(api.updateWorkspaceDomainDiscovery).toHaveBeenLastCalledWith("claim-1", 7, true));
    expect(await screen.findByText("Public discovery: Opted in; awaiting a current proof lease.")).toBeVisible();
  });

  it("does not report DNS success when the resolver is unavailable", async () => {
    const api = apiFixture(); api.verifyWorkspaceDomain.mockRejectedValue(new ApiError(503, "dns_timeout", "internal provider details"));
    renderPanel(api); await chooseVerify();
    await userEvent.click(screen.getByRole("button", { name: "Verify current DNS challenge" }));
    expect(await screen.findAllByText(/No verification success was recorded/)).toHaveLength(2);
    expect(screen.getByText(/Status: Awaiting DNS verification/)).toBeVisible();
    expect(screen.queryByText(/internal provider details/)).not.toBeInTheDocument();
  });

  it("strips cached TXT before step-up and clears inventory immediately when its retry loses access", async () => {
    const api = apiFixture();
    api.renewWorkspaceDomain.mockRejectedValueOnce(new ApiError(428, "step_up_required", "verify"))
      .mockRejectedValueOnce(new ApiError(403, "forbidden", "access revoked"));
    renderPanel(api); await openInstructions();
    await userEvent.click(screen.getByRole("button", { name: "New challenge for team.example.org" }));
    await userEvent.click(screen.getByRole("button", { name: "Create new challenge" }));
    const identity = await screen.findByRole("dialog", { name: "Confirm it is you" });
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
    await userEvent.type(within(identity).getByLabelText("Current password"), "synthetic password");
    await userEvent.click(within(identity).getByRole("button", { name: "Continue" }));
    await waitFor(() => expect(screen.queryByRole("heading", { name: "team.example.org" })).not.toBeInTheDocument());
    expect(screen.queryByLabelText("Domain")).not.toBeInTheDocument();
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(screen.getByText(/unavailable with your current access/)).toBeVisible();
  });

  it("ignores an inventory response from the previous actor credential", async () => {
    const old = deferred<{ data: WorkspaceDomainClaim[]; limits: { domains: number } }>();
    const api = apiFixture(); api.workspaceDomains.mockReturnValueOnce(old.promise).mockResolvedValue({ data: [], limits: { domains: 8 } });
    const view = renderPanel(api);
    await waitFor(() => expect(api.workspaceDomains).toHaveBeenCalledTimes(1));
    mocks.session = { ...mocks.session!, access_token: "replacement-access" };
    view.rerender(<StepUpProvider><WorkspaceDomainsPanel api={api} /></StepUpProvider>);
    await screen.findByText("0 / 8 retained domain claims.");
    await act(async () => { old.resolve({ data: [claim], limits: { domains: 8 } }); });
    expect(screen.queryByRole("heading", { name: "team.example.org" })).not.toBeInTheDocument();
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
  });

  it("hides private claims immediately when role or workspace scope is revoked", async () => {
    const view = renderPanel(); await openInstructions();
    mocks.session = { ...mocks.session!, user: { ...mocks.session!.user, access_scope: "conversation_only" } };
    view.rerender(<StepUpProvider><WorkspaceDomainsPanel api={view.api} /></StepUpProvider>);
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "team.example.org" })).not.toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("full workspace access");
  });

  it("keeps a current proof lease when renewing its separate challenge", async () => {
    const verified = { ...claim, status: "verified" as const, discovery_enabled: true, challenge_value: null, proof_expires_at: "2099-01-01T00:00:00Z", verified_at: "2026-10-05T00:00:00Z" };
    const api = apiFixture([verified]); api.renewWorkspaceDomain.mockResolvedValue({ ...verified, version: 2, challenge_value: "k-comms-domain=synthetic-renewal" });
    renderPanel(api);
    await userEvent.click(await screen.findByRole("button", { name: "New challenge for team.example.org" }));
    expect(screen.getByRole("alertdialog")).toHaveTextContent("existing live proof lease keeps its current expiry");
    await userEvent.click(screen.getByRole("button", { name: "Create new challenge" }));
    expect(await screen.findByText("Public discovery: Enabled.")).toBeVisible();
    await openInstructions(); expect(screen.getByText("k-comms-domain=synthetic-renewal")).toBeVisible();
  });

  it("labels expired proof and refuses consumed or expired TXT verification", async () => {
    renderPanel(apiFixture([{ ...claim, status: "verified", discovery_enabled: true, proof_expires_at: "2000-01-01T00:00:00Z", challenge_expires_at: "2000-01-01T00:00:00Z" }]));
    expect(await screen.findByText(/Status: Proof lease expired/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Verify DNS for team.example.org" })).toBeDisabled();
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
    expect(screen.getByText("Public discovery: Opted in; awaiting a current proof lease.")).toBeVisible();
  });

  it("removes only after reviewed confirmation and frees actual inventory capacity", async () => {
    const { api } = renderPanel();
    await userEvent.click(await screen.findByRole("button", { name: "Remove team.example.org" }));
    expect(api.removeWorkspaceDomain).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole("button", { name: "Remove claim" }));
    await screen.findByText("0 / 8 retained domain claims.");
    expect(api.removeWorkspaceDomain).toHaveBeenCalledWith("claim-1", 1);
    expect(screen.queryByText(claim.challenge_value!)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add domain claim" })).toBeEnabled();
  });

  it("uses the retained server inventory limit rather than offering a ninth claim", async () => {
    const full = Array.from({ length: 8 }, (_, index) => ({ ...claim, id: `claim-${index}`, domain: `team${index}.example.org` }));
    const { api } = renderPanel(apiFixture(full));
    await screen.findByText("8 / 8 retained domain claims.");
    await userEvent.type(screen.getByLabelText("Domain"), "other.example.org");
    expect(screen.getByRole("button", { name: "Add domain claim" })).toBeDisabled();
    expect(api.createWorkspaceDomain).not.toHaveBeenCalled();
    expect(screen.getByLabelText("Domain")).toHaveValue("other.example.org");
  });

  it("preserves an unsaved domain and opt-in intent across a conflicting create", async () => {
    const api = apiFixture([]); api.createWorkspaceDomain.mockRejectedValue(new ApiError(409, "domain_already_claimed", "claimed"));
    renderPanel(api); await screen.findByText("0 / 8 retained domain claims.");
    await userEvent.type(screen.getByLabelText("Domain"), "other.example.org");
    await userEvent.click(screen.getByLabelText("Opt in to public discovery after verification"));
    await userEvent.click(screen.getByRole("button", { name: "Add domain claim" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("cannot be claimed or verified");
    expect(screen.getByLabelText("Domain")).toHaveValue("other.example.org");
    expect(screen.getByLabelText("Opt in to public discovery after verification")).toBeChecked();
    expect(api.createWorkspaceDomain).toHaveBeenCalledTimes(1);
  });
});
