import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AdvancedPhoneControls } from "./AdvancedPhoneControls";
import type { PhoneCall, PhoneControlReceipt } from "./types";

const harness = vi.hoisted(() => ({ api: { phoneCapabilities: vi.fn(), phoneControls: vi.fn(), requestPhoneControl: vi.fn(), completePhoneControl: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
const call: PhoneCall = { id: "call-1", direction: "inbound", status: "answered", from_number: "+14155550101", to_number: "+14155550102", extension: "101", started_at: "2026-10-04T12:00:00Z", answered_at: "2026-10-04T12:00:05Z", ended_at: null, connected_seconds: 5, can_answer: false, can_join: true, can_end: true, active_on_this_device: true, control_state: "connected" };
const receipt: PhoneControlReceipt = { id: "control-1", call_id: call.id, action: "dtmf", status: "dispatching", dispatch: true, created_at: "2026-10-04T12:00:10Z", expires_at: "2026-10-04T12:01:10Z", completed_at: null, failure_reason: null };

describe("provider-backed phone controls", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.api.phoneCapabilities.mockResolvedValue({ dtmf: { supported: true, reason: null }, hold: { supported: false, reason: "pbx_required" } });
    harness.api.phoneControls.mockResolvedValue({ data: [], limit: 100 });
    harness.api.requestPhoneControl.mockResolvedValue(receipt);
    harness.api.completePhoneControl.mockResolvedValue({ ...receipt, status: "submitted", dispatch: false });
  });
  it("normalizes transfer presentation without inventing country codes or extension routing", async () => {
    harness.api.phoneCapabilities.mockResolvedValue({ blind_transfer: { supported: true }, consult_transfer: { supported: true } });
    harness.api.requestPhoneControl.mockResolvedValue({ ...receipt, action: "blind_transfer", status: "pending", dispatch: false });
    render(<AdvancedPhoneControls call={call} disabled={false} sendDtmf={vi.fn()} refresh={vi.fn().mockResolvedValue(undefined)} />);
    const input = await screen.findByLabelText("International destination");
    const user = userEvent.setup();
    await user.type(input, "101");
    expect(screen.getByRole("button", { name: "Transfer now" })).toBeDisabled();
    await user.clear(input);
    await user.type(input, "+1 (415) 555-0100");
    await user.click(screen.getByRole("button", { name: "Transfer now" }));
    expect(harness.api.requestPhoneControl).toHaveBeenCalledWith(call.id, expect.objectContaining({ action: "blind_transfer", destination: "+14155550100" }));
  });
  it("publishes one real SDK tone only after a fresh durable instruction and acknowledges submission", async () => {
    const sendDtmf = vi.fn().mockResolvedValue(undefined);
    render(<AdvancedPhoneControls call={call} disabled={false} sendDtmf={sendDtmf} refresh={vi.fn().mockResolvedValue(undefined)} />);
    await userEvent.click(await screen.findByRole("button", { name: "Send tone 5" }));
    await waitFor(() => expect(sendDtmf).toHaveBeenCalledExactlyOnceWith("5"));
    expect(harness.api.completePhoneControl).toHaveBeenCalledWith(call.id, receipt.id, "submitted");
    expect(screen.queryByRole("button", { name: "Hold" })).not.toBeInTheDocument();
    expect(screen.getByText(/Carrier receipt cannot be confirmed/)).toBeInTheDocument();
  });
  it("lost authorization responses retry the same key and never replay a tone", async () => {
    const sendDtmf = vi.fn();
    harness.api.requestPhoneControl.mockRejectedValueOnce(new Error("connection lost")).mockResolvedValueOnce({ ...receipt, dispatch: false });
    render(<AdvancedPhoneControls call={call} disabled={false} sendDtmf={sendDtmf} refresh={vi.fn().mockResolvedValue(undefined)} />);
    await userEvent.click(await screen.findByRole("button", { name: "Send tone 5" }));
    await userEvent.click(await screen.findByRole("button", { name: "Retry control request" }));
    const first = harness.api.requestPhoneControl.mock.calls[0];
    const second = harness.api.requestPhoneControl.mock.calls[1];
    if (!first || !second) throw new Error("Both control requests must be observed.");
    expect(first[1]).toEqual(second[1]);
    expect(sendDtmf).not.toHaveBeenCalled();
    expect(harness.api.completePhoneControl).not.toHaveBeenCalled();
  });
  it("offers an explicit safe cancellation for an uncertain consultation while new forward controls stay blocked", async () => {
    const unknown = { ...receipt, action: "consult_transfer", status: "unknown", dispatch: false };
    harness.api.phoneControls.mockResolvedValue({ data: [unknown], limit: 100 });
    harness.api.phoneCapabilities.mockResolvedValue({ dtmf: { supported: true, reason: null }, cancel_transfer: { supported: true, reason: null } });
    harness.api.requestPhoneControl.mockResolvedValue({ ...receipt, id: "cancel-1", action: "cancel_transfer", status: "pending", dispatch: false });
    const sendDtmf = vi.fn();
    render(<AdvancedPhoneControls call={call} disabled={false} sendDtmf={sendDtmf} refresh={vi.fn().mockResolvedValue(undefined)} />);
    expect(await screen.findByRole("button", { name: "Send tone 5" })).toBeDisabled();
    await userEvent.click(await screen.findByRole("button", { name: "Cancel uncertain consultation" }));
    await waitFor(() => expect(harness.api.requestPhoneControl).toHaveBeenCalledWith(call.id, expect.objectContaining({ action: "cancel_transfer" })));
    expect(sendDtmf).not.toHaveBeenCalled();
  });
  it.each(["voicemail", "transferred"] as const)("removes forward controls after provider confirms %s while media events catch up", async (control_state) => {
    harness.api.phoneCapabilities.mockResolvedValue({ dtmf: { supported: true }, consult_transfer: { supported: true }, voicemail: { supported: true } });
    harness.api.phoneControls.mockResolvedValue({ data: [{ ...receipt, status: "submitted", dispatch: false }], limit: 100 });
    render(<AdvancedPhoneControls call={{ ...call, control_state }} disabled={false} sendDtmf={vi.fn()} refresh={vi.fn().mockResolvedValue(undefined)} />);
    await screen.findByText("Latest dtmf: submitted");
    expect(screen.queryByRole("button", { name: "Send tone 5" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Consult before transfer" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Send to voicemail" })).not.toBeInTheDocument();
    expect(harness.api.requestPhoneControl).not.toHaveBeenCalled();
  });
  it("SDK transport failure is acknowledged as unknown and disconnected media disables controls", async () => {
    const sendDtmf = vi.fn().mockRejectedValue(new Error("transport lost"));
    const mounted = render(<AdvancedPhoneControls call={call} disabled={false} sendDtmf={sendDtmf} refresh={vi.fn().mockResolvedValue(undefined)} />);
    await userEvent.click(await screen.findByRole("button", { name: "Send tone #" }));
    await waitFor(() => expect(harness.api.completePhoneControl).toHaveBeenCalledWith(call.id, receipt.id, "unknown"));
    mounted.rerender(<AdvancedPhoneControls call={call} disabled={true} sendDtmf={sendDtmf} refresh={vi.fn().mockResolvedValue(undefined)} />);
    expect(screen.getByRole("button", { name: "Send tone 1" })).toBeDisabled();
  });
});
