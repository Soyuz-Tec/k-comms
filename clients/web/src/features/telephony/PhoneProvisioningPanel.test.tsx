import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { PhoneProvisioningPanel } from "./PhoneProvisioningPanel";

const harness = vi.hoisted(() => ({ api: { phoneProvisioningState: vi.fn(), inspectPhoneProvisioning: vi.fn(), applyPhoneProvisioning: vi.fn(), reconcilePhoneProvisioning: vi.fn() },
  users: [{ id: "member", display_name: "Workspace member", account_type: "human", access_scope: "workspace", status: "active" },
    { id: "limited", display_name: "Limited owner", account_type: "human", access_scope: "conversation_only", status: "active" }], stepUp: vi.fn() }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ users: harness.users }) }));
vi.mock("../../app/step-up", () => ({ useStepUp: () => ({ runWithStepUp: harness.stepUp }), stepUpWasCancelled: () => false }));
const provider = { enabled: true, ready: true, reason: null, number_purchase: false, trunk_credentials_edit: false };
const desired = { user_id: "member", phone_number: "+14155550123", extension: "101", inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out" };
const receipt = { id: "command", request_id: "request", version: 3, assignment_version: 0, status: "unknown", desired, dispatch_ready: false, dispatch_rule_id: null, observed_at: null, failure_reason: "provider_outcome_unknown", effect_in_progress: false };
beforeEach(() => { vi.clearAllMocks(); harness.stepUp.mockImplementation((action: () => unknown) => action()); });
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
