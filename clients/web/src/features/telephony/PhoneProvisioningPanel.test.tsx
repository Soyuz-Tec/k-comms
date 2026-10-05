import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { PhoneProvisioningPanel } from "./PhoneProvisioningPanel";

import type { Session } from "../../types";

const harness = vi.hoisted(() => ({ session: null as Session | null, api: { phoneProvisioningState: vi.fn(), inspectPhoneProvisioning: vi.fn(), applyPhoneProvisioning: vi.fn(), reconcilePhoneProvisioning: vi.fn() },
  users: [{ id: "member", display_name: "Workspace member", account_type: "human", access_scope: "workspace", status: "active" },
    { id: "limited", display_name: "Limited owner", account_type: "human", access_scope: "conversation_only", status: "active" }], stepUp: vi.fn() }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: harness.session }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ users: harness.users }) }));
vi.mock("../../app/step-up", () => ({ useStepUp: () => ({ runWithStepUp: harness.stepUp }), stepUpWasCancelled: () => false }));
const provider = { enabled: true, ready: true, reason: null, number_purchase: false, trunk_credentials_edit: false };
const desired = { user_id: "member", phone_number: "+14155550123", extension: "101", inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out" };
const receipt = { id: "command", request_id: "request", version: 3, assignment_version: 0, status: "unknown", desired, dispatch_ready: false, dispatch_rule_id: null, observed_at: null, failure_reason: "provider_outcome_unknown", effect_in_progress: false };

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

beforeEach(() => { vi.clearAllMocks(); harness.session = currentSession(); harness.stepUp.mockImplementation((action: () => unknown) => action()); });
it("shows disabled management honestly and offers no effect action", async () => {
  harness.api.phoneProvisioningState.mockResolvedValue({ provider: { ...provider, enabled: false, ready: false }, assignment_version: 0, commands: [] });
  render(<PhoneProvisioningPanel onApplied={vi.fn()} onManagementMode={vi.fn()} />);
  expect(await screen.findByText(/off by default/)).toBeVisible();
  expect(screen.queryByRole("button", { name: "Inspect setup" })).not.toBeInTheDocument();
  expect(harness.api.applyPhoneProvisioning).not.toHaveBeenCalled();
});
it("restricts assignment choices to active workspace humans", async () => {
  harness.api.phoneProvisioningState.mockResolvedValue({ provider, assignment_version: 0, commands: [] });
  render(<PhoneProvisioningPanel onApplied={vi.fn()} onManagementMode={vi.fn()} />);
  expect(await screen.findByRole("option", { name: "Workspace member" })).toBeVisible();
  expect(screen.queryByRole("option", { name: "Limited owner" })).not.toBeInTheDocument();
});
it("unknown effect exposes read-only reconciliation with receipt CAS and never Apply", async () => {
  harness.api.phoneProvisioningState.mockResolvedValue({ provider, assignment_version: 0, commands: [receipt] });
  harness.api.reconcilePhoneProvisioning.mockResolvedValue({ ...receipt, version: 5 });
  render(<PhoneProvisioningPanel onApplied={vi.fn()} onManagementMode={vi.fn()} />);
  const user = userEvent.setup();
  await user.type(await screen.findByLabelText("Reason for reconciling"), "Observe original create");
  expect(screen.queryByRole("button", { name: "Apply verified setup" })).not.toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "Reconcile original effect" }));
  await waitFor(() => expect(harness.api.reconcilePhoneProvisioning).toHaveBeenCalledWith("command", { version: 3, reason: "Observe original create" }));
  expect(harness.api.applyPhoneProvisioning).not.toHaveBeenCalled();
  expect(harness.stepUp).toHaveBeenCalledOnce();
});


it.each([
  ["access credential", (s: Session): Session => ({ ...s, access_token: "new-private-access" })],
  ["refresh credential", (s: Session): Session => ({ ...s, refresh_token: "new-private-refresh" })],
  ["owner role", (s: Session): Session => ({ ...s, user: { ...s.user, role: "admin" } })],
  ["owner version", (s: Session): Session => ({ ...s, user: { ...s.user, version: 2 } })],
  ["tenant", (s: Session): Session => ({ ...s, tenant: { ...s.tenant, id: "other" }, user: { ...s.user, tenant_id: "other" } })],
  ["user", (s: Session): Session => ({ ...s, user: { ...s.user, id: "other" }, device: { ...s.device, user_id: "other" } })],
  ["device", (s: Session): Session => ({ ...s, device: { ...s.device, id: "other" } })]
])("fences a delayed old provider read after changing %s", async (_name, change) => {
  const old = deferred<unknown>();
  harness.api.phoneProvisioningState.mockImplementationOnce(() => old.promise)
    .mockResolvedValue({ provider, assignment_version: 0, commands: [] });
  const props = { onApplied: vi.fn(), onManagementMode: vi.fn() };
  const view = render(<PhoneProvisioningPanel {...props} />);
  await waitFor(() => expect(harness.api.phoneProvisioningState).toHaveBeenCalledOnce());
  harness.session = change(currentSession());
  view.rerender(<PhoneProvisioningPanel {...props} />);
  await screen.findByRole("button", { name: "Inspect setup" });
  await act(async () => old.resolve({ provider: { ...provider, enabled: false }, assignment_version: 7, commands: [receipt] }));
  expect(screen.queryByText(/\+14155550123 · unknown/)).not.toBeInTheDocument();
  expect(props.onManagementMode).toHaveBeenCalledExactlyOnceWith(true);
  expect(harness.api.phoneProvisioningState).toHaveBeenCalledTimes(2);
  expect(props.onApplied).not.toHaveBeenCalled();
  expect(view.container.innerHTML).not.toContain("private-owner-access");
  expect(view.container.innerHTML).not.toContain("private-owner-refresh");
});

it.each([
  ["role", (s: Session): Session => ({ ...s, user: { ...s.user, role: "member" } })],
  ["status", (s: Session): Session => ({ ...s, user: { ...s.user, status: "suspended" } })],
  ["account type", (s: Session): Session => ({ ...s, user: { ...s.user, account_type: "service" } })],
  ["access scope", (s: Session): Session => ({ ...s, user: { ...s.user, access_scope: "conversation_only" } })],
  ["tenant status", (s: Session): Session => ({ ...s, tenant: { ...s.tenant, status: "suspended" } })],
  ["device revocation", (s: Session): Session => ({ ...s, device: { ...s.device, revoked_at: "2026-10-05T00:00:00Z" } })]
])("clears receipts and refuses delayed replay after %s withdrawal", async (_name, change) => {
  const old = deferred<unknown>();
  harness.api.phoneProvisioningState.mockResolvedValueOnce({ provider, assignment_version: 0, commands: [receipt] })
    .mockImplementationOnce(() => old.promise);
  const props = { onApplied: vi.fn(), onManagementMode: vi.fn() };
  const view = render(<PhoneProvisioningPanel {...props} />);
  await screen.findByText(/\+14155550123 · unknown/);
  await userEvent.setup().click(screen.getByRole("button", { name: "Refresh provider receipts" }));
  harness.session = change(currentSession());
  view.rerender(<PhoneProvisioningPanel {...props} />);
  expect(screen.getByRole("alert")).toHaveTextContent("current owner or administrator with full workspace access");
  await act(async () => old.resolve({ provider, assignment_version: 0, commands: [receipt] }));
  expect(screen.queryByText(/\+14155550123/)).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Reconcile original effect" })).not.toBeInTheDocument();
  expect(harness.api.phoneProvisioningState).toHaveBeenCalledTimes(2);
  expect(props.onManagementMode).toHaveBeenCalledOnce();
  expect(props.onApplied).not.toHaveBeenCalled();
});

it.each(["apply", "reconcile"] as const)("discards an old %s completion after same-identity credential and version changes", async (mode) => {
  const old = deferred<unknown>();
  const command = { ...receipt, status: mode === "apply" ? "verified" : "unknown" };
  harness.api.phoneProvisioningState.mockResolvedValueOnce({ provider, assignment_version: 0, commands: [command] })
    .mockResolvedValue({ provider, assignment_version: 0, commands: [] });
  const request = mode === "apply" ? harness.api.applyPhoneProvisioning : harness.api.reconcilePhoneProvisioning;
  request.mockImplementationOnce(() => old.promise);
  const props = { onApplied: vi.fn(), onManagementMode: vi.fn() };
  const view = render(<PhoneProvisioningPanel {...props} />);
  const user = userEvent.setup();
  await user.type(await screen.findByLabelText(mode === "apply" ? "Reason for applying" : "Reason for reconciling"), "Original authorized intent");
  await user.click(screen.getByRole("button", { name: mode === "apply" ? "Apply verified setup" : "Reconcile original effect" }));
  await waitFor(() => expect(request).toHaveBeenCalledOnce());
  const s = currentSession();
  harness.session = { ...s, access_token: "rotated-private-access", user: { ...s.user, version: 2, role: "admin" } };
  view.rerender(<PhoneProvisioningPanel {...props} />);
  await screen.findByRole("button", { name: "Inspect setup" });
  await act(async () => old.resolve({ ...receipt, status: "applied", version: 5 }));
  expect(screen.queryByText(/Provider binding and assignment saved/)).not.toBeInTheDocument();
  expect(props.onApplied).not.toHaveBeenCalled();
  expect(harness.api.phoneProvisioningState).toHaveBeenCalledTimes(2);
  expect(request).toHaveBeenCalledOnce();
});

it("preserves an unsaved inspection under equivalent session objects and clears it on credential rotation", async () => {
  harness.api.phoneProvisioningState.mockResolvedValue({ provider, assignment_version: 0, commands: [] });
  const props = { onApplied: vi.fn(), onManagementMode: vi.fn() };
  const view = render(<PhoneProvisioningPanel {...props} />);
  await userEvent.setup().type(await screen.findByLabelText("Phone number"), "+14155550123");
  const s = currentSession();
  harness.session = { ...s, user: { ...s.user }, tenant: { ...s.tenant }, device: { ...s.device }, received_at: 123456 };
  view.rerender(<PhoneProvisioningPanel {...props} />);
  expect(screen.getByLabelText("Phone number")).toHaveValue("+14155550123");
  expect(harness.api.phoneProvisioningState).toHaveBeenCalledOnce();
  harness.session = { ...harness.session, access_token: "new-private-access" };
  view.rerender(<PhoneProvisioningPanel {...props} />);
  expect(await screen.findByLabelText("Phone number")).toHaveValue("");
  expect(harness.api.phoneProvisioningState).toHaveBeenCalledTimes(2);
});


it("clears an uncertain inspection and rejects its old completion after credential rotation", async () => {
  const old = deferred<unknown>();
  harness.api.phoneProvisioningState.mockResolvedValue({ provider, assignment_version: 0, commands: [] });
  harness.api.inspectPhoneProvisioning.mockImplementationOnce(() => old.promise);
  const props = { onApplied: vi.fn(), onManagementMode: vi.fn() };
  const view = render(<PhoneProvisioningPanel {...props} />);
  const user = userEvent.setup();
  await user.type(await screen.findByLabelText("Phone number"), "+14155550123");
  await user.type(screen.getByLabelText("Inbound trunk ID"), "ST_in");
  await user.type(screen.getByLabelText("Outbound trunk ID"), "ST_out");
  await user.selectOptions(screen.getByLabelText("Assigned workspace member"), "member");
  await user.type(screen.getByLabelText("Extension"), "101");
  await user.type(screen.getByLabelText("Reason"), "Original inspection reason");
  await user.click(screen.getByRole("button", { name: "Inspect setup" }));
  await waitFor(() => expect(harness.api.inspectPhoneProvisioning).toHaveBeenCalledOnce());
  const submitted = harness.api.inspectPhoneProvisioning.mock.calls[0]?.[0];
  expect(submitted).toMatchObject({ assignment_version: 0, phone_number: "+14155550123", reason: "Original inspection reason" });
  expect(submitted.idempotency_key).toMatch(/^[0-9a-f-]{36}$/);
  harness.session = { ...currentSession(), access_token: "new-private-access" };
  view.rerender(<PhoneProvisioningPanel {...props} />);
  expect(await screen.findByLabelText("Phone number")).toHaveValue("");
  expect(screen.getByLabelText("Reason")).toHaveValue("");
  await act(async () => old.resolve({ ...receipt, status: "verified" }));
  expect(screen.queryByText(/Provider resources inspected/)).not.toBeInTheDocument();
  expect(harness.api.phoneProvisioningState).toHaveBeenCalledTimes(2);
  expect(harness.api.inspectPhoneProvisioning).toHaveBeenCalledOnce();
  expect(props.onApplied).not.toHaveBeenCalled();
});
