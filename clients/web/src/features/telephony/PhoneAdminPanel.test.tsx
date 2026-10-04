import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PhoneAdminPanel } from "./PhoneAdminPanel";

const harness = vi.hoisted(() => { const load = vi.fn(); const update = vi.fn(); return { api: { phoneNumberAssignment: load, updatePhoneNumber: update }, load, update, stepUp: vi.fn(), refresh: vi.fn() }; });
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ users: [{ id: "user-1", display_name: "Member One", status: "active" }, { id: "service-1", display_name: "Automation", status: "active", account_type: "service" }] }) }));
vi.mock("../../app/step-up", () => ({ useStepUp: () => ({ runWithStepUp: harness.stepUp }), stepUpWasCancelled: () => false }));
vi.mock("./TelephonyProvider", () => ({ useTelephony: () => ({ refresh: harness.refresh }) }));

describe("phone provisioning", () => {
  beforeEach(() => { vi.clearAllMocks(); harness.load.mockResolvedValue(null); harness.stepUp.mockImplementation((action: () => Promise<unknown>) => action()); harness.update.mockResolvedValue({ id: "line-1", phone_number: "+14155550123", extension: "101", user_id: "user-1", inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out" }); });
  it("assigns a number only through step-up with an audit reason, excludes service accounts", async () => {
    render(<PhoneAdminPanel />);
    const number = await screen.findByLabelText("Phone number");
    expect(screen.queryByRole("option", { name: "Automation" })).not.toBeInTheDocument();
    const user = userEvent.setup();
    await user.type(number, "+14155550123");
    await user.type(screen.getByLabelText("Extension"), "101");
    await user.selectOptions(screen.getByLabelText("Assigned member"), "user-1");
    await user.type(screen.getByLabelText("Inbound SIP trunk ID"), "ST_in");
    await user.type(screen.getByLabelText("Outbound SIP trunk ID"), "ST_out");
    await user.type(screen.getByLabelText("Reason for this change"), "First phone pilot");
    await user.click(screen.getByRole("button", { name: "Save phone line" }));
    await screen.findByText("Phone line saved.");
    expect(harness.stepUp).toHaveBeenCalledOnce();
    await waitFor(() => expect(harness.update).toHaveBeenCalledWith({ phone_number: "+14155550123", extension: "101", user_id: "user-1", inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out", reason: "First phone pilot" }));
    expect(harness.refresh).toHaveBeenCalled();
    expect(screen.getByLabelText("Reason for this change")).toHaveValue("");
  });
});
