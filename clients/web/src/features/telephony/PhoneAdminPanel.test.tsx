import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PhoneAdminPanel } from "./PhoneAdminPanel";

import type { Session } from "../../types";

const harness = vi.hoisted(() => { const load = vi.fn(); const update = vi.fn(); return { session: null as Session | null, api: { phoneProvisioningState: vi.fn().mockResolvedValue({ provider: { enabled: false, ready: false, reason: "provider_management_disabled", number_purchase: false, trunk_credentials_edit: false }, assignment_version: 0, commands: [] }), voicemailMailbox: vi.fn().mockResolvedValue(null), phoneRoutes: vi.fn().mockResolvedValue({ data: [], limit: 100 }), phoneCapabilities: vi.fn().mockResolvedValue({}), phoneAdminConfiguration: load, updatePhoneNumber: update }, load, update, stepUp: vi.fn(), refresh: vi.fn(), users: [] as { id: string; display_name: string; status: string; account_type?: string; access_scope?: string }[] }; });
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: harness.session }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ users: harness.users }) }));
vi.mock("../../app/step-up", () => ({ useStepUp: () => ({ runWithStepUp: harness.stepUp }), stepUpWasCancelled: () => false }));
vi.mock("./TelephonyProvider", () => ({ useTelephony: () => ({ refresh: harness.refresh }) }));

const configuration = { enabled: false, configured: false, provider_ready: false, line_assigned: false, provider: "livekit_sip", number: null, can_manage: true };
async function fillAssignment() {
  const user = userEvent.setup();
  await user.type(await screen.findByLabelText("Phone number"), "+14155550123");
  await user.type(screen.getByLabelText("Extension"), "101");
  await user.selectOptions(screen.getByLabelText("Assigned member"), "user-1");
  await user.type(screen.getByLabelText("Inbound SIP trunk ID"), "ST_in");
  await user.type(screen.getByLabelText("Outbound SIP trunk ID"), "ST_out");
  await user.type(screen.getByLabelText("Reason for this change"), "First phone pilot");
  return user;
}


function currentSession(): Session {
  return { access_token: "private-owner-access", refresh_token: "private-owner-refresh", token_type: "Bearer", expires_in: 900,
    tenant: { id: "tenant", slug: "workspace", name: "Workspace", status: "active" },
    user: { id: "owner", tenant_id: "tenant", display_name: "Owner", role: "owner", status: "active", version: 1, account_type: "human", access_scope: "workspace" },
    device: { id: "device", user_id: "owner", name: "Browser", platform: "test" } };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}

describe("phone provisioning", () => {
  beforeEach(() => { vi.clearAllMocks(); harness.session = currentSession(); harness.users = [{ id: "user-1", display_name: "Member One", status: "active", account_type: "human", access_scope: "workspace" }, { id: "service-1", display_name: "Automation", status: "active", account_type: "service" }, { id: "guest-1", display_name: "Guest", status: "active", account_type: "guest" }, { id: "inactive-1", display_name: "Inactive", status: "suspended" }]; harness.load.mockResolvedValue(configuration); harness.stepUp.mockImplementation((action: () => Promise<unknown>) => action()); harness.refresh.mockResolvedValue(undefined); harness.update.mockResolvedValue({ id: "line-1", phone_number: "+14155550123", extension: "101", user_id: "user-1", inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out" }); });
  it("guides setup from provider to verification and saves only through step-up with an audit reason", async () => {
    render(<PhoneAdminPanel />);
    const user = await fillAssignment();
    expect(screen.getByRole("heading", { name: "1. Provider" })).toBeVisible();
    expect(screen.getByRole("group", { name: "2. Number" })).toBeVisible();
    expect(screen.getByRole("group", { name: "3. Assignment" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "4. Verify" })).toBeVisible();
    expect(screen.getByText("Phone service is off")).toBeVisible();
    for (const name of ["Automation", "Guest", "Inactive"]) expect(screen.queryByRole("option", { name })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Save phone line" }));
    await screen.findByText("Phone assignment saved. Carrier connectivity still needs to be verified with your service operator.");
    expect(harness.stepUp).toHaveBeenCalledOnce();
    await waitFor(() => expect(harness.update).toHaveBeenCalledWith({ phone_number: "+14155550123", extension: "101", user_id: "user-1", inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out", reason: "First phone pilot", version: 0 }));
    expect(harness.refresh).toHaveBeenCalled();
    expect(screen.getByLabelText("Reason for this change")).toHaveValue("");
    expect(screen.getByText("Phone service is off")).toBeVisible();
  });

  it("distinguishes configured provider readiness from carrier verification", async () => {
    harness.load.mockResolvedValue({ ...configuration, enabled: true, provider_ready: true });
    render(<PhoneAdminPanel />);
    expect(await screen.findByText("Provider configuration ready")).toBeVisible();
    expect(screen.getByText("No carrier number saved")).toBeVisible();
    expect(screen.getByText(/Saving this form does not verify carrier connectivity/)).toBeVisible();
    expect(harness.update).not.toHaveBeenCalled();
    expect(harness.refresh).not.toHaveBeenCalled();
  });

  it("validates trunk IDs before password verification or a write", async () => {
    render(<PhoneAdminPanel />);
    const user = await fillAssignment();
    await user.clear(screen.getByLabelText("Inbound SIP trunk ID"));
    await user.type(screen.getByLabelText("Inbound SIP trunk ID"), "ST invalid");
    await user.click(screen.getByRole("button", { name: "Save phone line" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("SIP trunk IDs must contain 2–200 letters, digits, underscores, or hyphens.");
    expect(harness.stepUp).not.toHaveBeenCalled();
    expect(harness.update).not.toHaveBeenCalled();
  });

  it("preserves an unsaved assignment when refreshing provider status", async () => {
    render(<PhoneAdminPanel />);
    const user = await fillAssignment();
    await user.click(screen.getByRole("button", { name: "Refresh setup status" }));
    await waitFor(() => expect(harness.load).toHaveBeenCalledTimes(2));
    expect(screen.getByLabelText("Phone number")).toHaveValue("+14155550123");
    expect(screen.getByLabelText("Reason for this change")).toHaveValue("First phone pilot");
    expect(harness.stepUp).not.toHaveBeenCalled();
    expect(harness.update).not.toHaveBeenCalled();
  });

  it("restores the saved member when the directory arrives after phone settings", async () => {
    harness.users = [];
    harness.load.mockResolvedValue({ ...configuration, line_assigned: true, number: { id: "line-1", phone_number: "+14155550123", extension: "101", user_id: "user-1" } });
    const view = render(<PhoneAdminPanel />);
    expect(await screen.findByLabelText("Assigned member")).toHaveValue("");
    harness.users = [{ id: "user-1", display_name: "Member One", status: "active", account_type: "human", access_scope: "workspace" }];
    view.rerender(<PhoneAdminPanel />);
    expect(screen.getByLabelText("Assigned member")).toHaveValue("user-1");
    expect(harness.update).not.toHaveBeenCalled();
  });

  it("keeps settings unavailable until a failed configuration fetch is retried", async () => {
    harness.load.mockRejectedValueOnce(new Error("Settings unavailable"));
    render(<PhoneAdminPanel />);
    expect(await screen.findByRole("alert")).toHaveTextContent("Settings unavailable");
    expect(screen.queryByRole("button", { name: "Save phone line" })).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Retry phone settings" }));
    expect(await screen.findByLabelText("Phone number")).toBeVisible();
    expect(harness.update).not.toHaveBeenCalled();
  });

  it("does not replay a delayed manual configuration across same-identity access and role changes", async () => {
    const old = deferred<unknown>();
    harness.load.mockImplementationOnce(() => old.promise).mockResolvedValue(configuration);
    const view = render(<PhoneAdminPanel />);
    await waitFor(() => expect(harness.load).toHaveBeenCalledOnce());
    const s = currentSession();
    harness.session = { ...s, access_token: "rotated-private-access", user: { ...s.user, role: "admin", version: 2 } };
    view.rerender(<PhoneAdminPanel />);
    await screen.findByLabelText("Phone number");
    await act(async () => old.resolve({ ...configuration, number: { id: "old-line", phone_number: "+442012345678", user_id: "user-1", extension: "909" } }));
    expect(screen.getByLabelText("Phone number")).toHaveValue("");
    expect(screen.queryByText(/\+442012345678/)).not.toBeInTheDocument();
    expect(harness.load).toHaveBeenCalledTimes(2);
    expect(harness.update).not.toHaveBeenCalled();
  });

  it("does not publish an old manual save completion after refresh credential and version changes", async () => {
    const old = deferred<unknown>();
    harness.update.mockImplementationOnce(() => old.promise);
    const view = render(<PhoneAdminPanel />);
    const user = await fillAssignment();
    await user.click(screen.getByRole("button", { name: "Save phone line" }));
    await waitFor(() => expect(harness.update).toHaveBeenCalledOnce());
    const s = currentSession();
    harness.session = { ...s, refresh_token: "rotated-private-refresh", user: { ...s.user, version: 2 } };
    view.rerender(<PhoneAdminPanel />);
    await screen.findByLabelText("Phone number");
    await act(async () => old.resolve({ id: "old-line", phone_number: "+442012345678", extension: "909", user_id: "user-1", inbound_trunk_id: "ST_old", outbound_trunk_id: "ST_old_out" }));
    expect(screen.getByLabelText("Phone number")).toHaveValue("");
    expect(screen.queryByText(/Phone assignment saved/)).not.toBeInTheDocument();
    expect(harness.refresh).not.toHaveBeenCalled();
    expect(harness.update).toHaveBeenCalledOnce();
  });

  it("preserves an equivalent-session draft then erases manual setup on permission withdrawal", async () => {
    const view = render(<PhoneAdminPanel />);
    await fillAssignment();
    const s = currentSession();
    harness.session = { ...s, tenant: { ...s.tenant }, user: { ...s.user }, device: { ...s.device }, received_at: 1000 };
    view.rerender(<PhoneAdminPanel />);
    expect(screen.getByLabelText("Phone number")).toHaveValue("+14155550123");
    expect(screen.getByLabelText("Reason for this change")).toHaveValue("First phone pilot");
    expect(harness.load).toHaveBeenCalledOnce();
    harness.session = { ...s, user: { ...s.user, access_scope: "conversation_only", version: 2 } };
    view.rerender(<PhoneAdminPanel />);
    expect(screen.getByRole("alert")).toHaveTextContent("current owner or administrator with full workspace access");
    expect(screen.queryByLabelText("Phone number")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Reason for this change")).not.toBeInTheDocument();
    expect(harness.update).not.toHaveBeenCalled();
    expect(view.container.innerHTML).not.toContain("private-owner-access");
  });
});
