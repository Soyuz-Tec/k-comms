import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/errors";
import { TelephonyProvider, useTelephony } from "./TelephonyProvider";
import { phoneMediaIsBusy, setPhoneMediaBusy } from "./mediaOwnership";
import type { PhoneCall, PhoneConfiguration } from "./types";

const incoming: PhoneCall = { id: "phone-1", direction: "inbound", status: "ringing", from_number: "+14155550199", to_number: "+14155550123", extension: "101", started_at: "2026-10-03T12:00:00Z", answered_at: null, ended_at: null, connected_seconds: 0, can_answer: true, can_join: false, can_end: false, active_on_this_device: false };
const owned: PhoneCall = { ...incoming, can_answer: false, can_join: true, can_end: true, active_on_this_device: true };
const credential = { server_url: "wss://media.example.test", participant_token: "short-lived-token", expires_in: 60 };
const configuration: PhoneConfiguration = { enabled: true, configured: true, provider: "livekit_sip", number: { id: "line-1", phone_number: incoming.to_number, extension: "101", user_id: "user-1" }, can_manage: true };
const page = (calls: PhoneCall[]) => ({ data: calls, page: { limit: 30, has_more: false, next_cursor: null } });

const harness = vi.hoisted(() => ({
  api: { phoneCapabilities: vi.fn(), phoneControls: vi.fn(), phoneConfiguration: vi.fn(), phoneCalls: vi.fn(), phoneCall: vi.fn(), answerPhoneCall: vi.fn(), joinPhoneCall: vi.fn(), dialPhone: vi.fn(), rejectPhoneCall: vi.fn(), endPhoneCall: vi.fn(), requestPhoneControl: vi.fn(), reconcilePhoneControl: vi.fn() },
  permission: vi.fn(), stop: vi.fn(), connect: vi.fn(), disconnect: vi.fn(), muted: vi.fn(), conversationBusy: false,
  onState: null as null | ((state: "connecting" | "connected" | "disconnected") => void)
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: { user: { id: "user-1" }, device: { id: "device-1" } }, mediaActionsAllowed: true }) }));
vi.mock("../calls/CallSessionProvider", () => ({ useCallSession: () => ({ launchRequest: harness.conversationBusy ? {} : null, sessionState: null }) }));
vi.mock("./phoneMedia", () => ({ PhoneMedia: class {
  constructor(_credential: unknown, _container: unknown, onState: typeof harness.onState) { harness.onState = onState; }
  connect = harness.connect;
  disconnect = harness.disconnect;
  setMuted = harness.muted;
  startPlayback = vi.fn();
} }));

function Controls() {
  const phone = useTelephony();
  return <><button onClick={() => void phone.dial("+14155550199")}>Dial test</button><output aria-label="Phone error">{phone.error}</output><output aria-label="Phone line">{phone.configuration?.number?.phone_number || "Unavailable"}</output></>;
}
function mount() { return render(<MemoryRouter><TelephonyProvider><Controls /></TelephonyProvider></MemoryRouter>); }

describe("persistent phone controls", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    setPhoneMediaBusy(false);
    harness.conversationBusy = false;
    harness.api.phoneCapabilities.mockResolvedValue({});
    harness.api.phoneControls.mockResolvedValue({ data: [], limit: 100 });
    harness.api.phoneConfiguration.mockResolvedValue(configuration);
    harness.api.phoneCalls.mockResolvedValue(page([incoming]));
    harness.api.phoneCall.mockResolvedValue(owned);
    harness.api.answerPhoneCall.mockResolvedValue({ data: owned, credential });
    harness.api.joinPhoneCall.mockResolvedValue({ data: owned, credential });
    harness.api.dialPhone.mockResolvedValue({ data: { ...owned, direction: "outbound" }, credential });
    harness.api.endPhoneCall.mockResolvedValue({ ...owned, status: "ended", active_on_this_device: false, can_end: false });
    harness.api.rejectPhoneCall.mockResolvedValue({ ...incoming, status: "declined" });
    harness.permission.mockResolvedValue({ getTracks: () => [{ stop: harness.stop }] });
    harness.connect.mockImplementation(async () => { harness.onState?.("connected"); });
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia: harness.permission } });
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
  });

  it("shows incoming calls globally without taking microphone access and rejects without media", async () => {
    mount();
    await screen.findByRole("region", { name: `Incoming call from ${incoming.from_number}` });
    expect(harness.permission).not.toHaveBeenCalled();
    expect(harness.connect).not.toHaveBeenCalled();
    expect(phoneMediaIsBusy()).toBe(false);
    harness.api.phoneCalls.mockResolvedValue(page([]));
    await userEvent.click(screen.getByRole("button", { name: "Reject" }));
    await waitFor(() => expect(harness.api.rejectPhoneCall).toHaveBeenCalledWith(incoming.id));
    expect(harness.permission).not.toHaveBeenCalled();
  });

  it("offers and answers a shared line whose default assignee is another member", async () => {
    harness.api.phoneConfiguration.mockResolvedValue({ ...configuration, line_assigned: true, provider_ready: true, number: { ...configuration.number!, user_id: "default-assignee" } });
    mount();
    await userEvent.click(await screen.findByRole("button", { name: "Answer" }));
    await waitFor(() => expect(harness.api.answerPhoneCall).toHaveBeenCalledWith(incoming.id));
    expect(harness.connect).toHaveBeenCalledWith(credential);
  });

  it("answers only after microphone consent and hangs up with track cleanup", async () => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    harness.api.phoneCalls.mockResolvedValue(page([owned]));
    await userEvent.click(answer);
    await screen.findByText("Ringing · Audio connected");
    expect(harness.permission).toHaveBeenCalledWith({ audio: true });
    expect(harness.stop).toHaveBeenCalledOnce();
    expect(harness.api.answerPhoneCall).toHaveBeenCalledWith(incoming.id);
    expect(harness.connect).toHaveBeenCalledWith(credential);
    expect(phoneMediaIsBusy()).toBe(true);
    harness.api.phoneCalls.mockResolvedValue(page([]));
    await userEvent.click(screen.getByRole("button", { name: "End call" }));
    await screen.findByText("Ended");
    expect(harness.api.endPhoneCall).toHaveBeenCalledWith(incoming.id);
    expect(harness.disconnect).toHaveBeenCalled();
    expect(phoneMediaIsBusy()).toBe(false);
  });

  it.each(["voicemail", "transferred"] as const)("releases browser tracks after confirmed %s while retaining remote End authority", async (controlState) => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    harness.api.phoneCalls.mockResolvedValue(page([owned]));
    await userEvent.click(answer);
    await screen.findByText("Ringing · Audio connected");
    expect(phoneMediaIsBusy()).toBe(true);
    const browserTrackStop = vi.fn();
    harness.disconnect.mockImplementationOnce(browserTrackStop);
    const confirmed: PhoneCall = { ...owned, status: "answered", control_state: controlState, can_join: false };
    harness.api.phoneCalls.mockResolvedValue(page([confirmed]));
    fireEvent.focus(window);
    await waitFor(() => expect(browserTrackStop).toHaveBeenCalledOnce());
    expect(phoneMediaIsBusy()).toBe(false);
    expect(screen.getByRole("region", { name: "Current phone call" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "End call" })).toBeEnabled();
    expect(screen.queryByRole("button", { name: "Reconnect phone audio" })).not.toBeInTheDocument();
    expect(harness.api.endPhoneCall).not.toHaveBeenCalled();
    harness.api.phoneCalls.mockResolvedValue(page([]));
    await userEvent.click(screen.getByRole("button", { name: "End call" }));
    await waitFor(() => expect(harness.api.endPhoneCall).toHaveBeenCalledWith(owned.id));
    expect(harness.api.endPhoneCall).toHaveBeenCalledOnce();
  });

  it("keeps the current browser consultation when completion is uncertain and no transferred provider state is recorded", async () => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    harness.api.phoneCalls.mockResolvedValue(page([owned]));
    await userEvent.click(answer);
    await screen.findByText("Ringing · Audio connected");
    harness.api.phoneCalls.mockResolvedValue(page([{ ...owned, status: "answered", control_state: "consulting", can_join: false }]));
    harness.api.phoneControls.mockResolvedValue({ data: [{ id: "uncertain-completion", call_id: owned.id, action: "complete_transfer", status: "unknown", dispatch: false }], limit: 100 });
    fireEvent.focus(window);
    await screen.findByText("Answered · Audio connected");
    expect(harness.disconnect).not.toHaveBeenCalled();
    expect(phoneMediaIsBusy()).toBe(true);
    expect(screen.getByRole("button", { name: "End call" })).toBeEnabled();
    expect(harness.api.endPhoneCall).not.toHaveBeenCalled();
  });

  it("lets the owning device reconcile and cancel an uncertain consultation after media disconnect without starting forward controls", async () => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    harness.api.phoneCalls.mockResolvedValue(page([owned]));
    await userEvent.click(answer);
    await screen.findByText("Ringing · Audio connected");
    const held: PhoneCall = { ...owned, status: "answered", control_state: "held" };
    const unknown = { id: "uncertain-consult", call_id: owned.id, action: "consult_transfer", status: "unknown", dispatch: false };
    harness.api.phoneCapabilities.mockResolvedValue({ resume: { supported: true }, cancel_transfer: { supported: true } });
    harness.api.phoneControls.mockResolvedValue({ data: [unknown], limit: 100 });
    harness.api.phoneCalls.mockResolvedValue(page([held]));
    harness.api.reconcilePhoneControl.mockResolvedValue(unknown);
    harness.api.requestPhoneControl.mockResolvedValue({ ...unknown, id: "safe-cancel", action: "cancel_transfer", status: "pending" });
    fireEvent.focus(window);
    await screen.findByText("Answered · Audio connected");
    act(() => { harness.onState?.("disconnected"); });
    await screen.findByText("Answered · Audio disconnected");
    expect(await screen.findByRole("button", { name: "Resume" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Reconcile phone control" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Cancel uncertain consultation" })).toBeEnabled();
    await userEvent.click(screen.getByRole("button", { name: "Reconcile phone control" }));
    await waitFor(() => expect(harness.api.reconcilePhoneControl).toHaveBeenCalledWith(owned.id, unknown.id));
    await waitFor(() => expect(screen.getByRole("button", { name: "Cancel uncertain consultation" })).toBeEnabled());
    await userEvent.click(screen.getByRole("button", { name: "Cancel uncertain consultation" }));
    await waitFor(() => expect(harness.api.requestPhoneControl).toHaveBeenCalledWith(owned.id, expect.objectContaining({ action: "cancel_transfer", idempotency_key: expect.any(String) })));
    expect(harness.api.requestPhoneControl).toHaveBeenCalledOnce();
    expect(harness.api.joinPhoneCall).not.toHaveBeenCalled();
    expect(harness.api.endPhoneCall).not.toHaveBeenCalled();
    expect(harness.connect).toHaveBeenCalledOnce();
  });

  it("keeps an incoming call unclaimed when microphone permission is denied", async () => {
    harness.permission.mockRejectedValue(new DOMException("Permission denied", "NotAllowedError"));
    mount();
    await userEvent.click(await screen.findByRole("button", { name: "Answer" }));
    await screen.findByRole("alert");
    expect(screen.getByRole("alert")).toHaveTextContent("Phone audio could not connect");
    expect(harness.api.answerPhoneCall).not.toHaveBeenCalled();
    expect(harness.connect).not.toHaveBeenCalled();
    expect(phoneMediaIsBusy()).toBe(false);
  });

  it("prevents phone audio while a conversation call is joining", async () => {
    harness.conversationBusy = true;
    mount();
    expect(await screen.findByRole("button", { name: "Answer" })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: "Dial test" }));
    expect(harness.api.dialPhone).not.toHaveBeenCalled();
    expect(harness.permission).not.toHaveBeenCalled();
    expect(screen.getByLabelText("Phone error")).toHaveTextContent("Leave your conversation call");
  });

  it("releases local media when another device owns the call or authorization is revoked", async () => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    harness.api.phoneCalls.mockResolvedValue(page([owned]));
    await userEvent.click(answer);
    await screen.findByText("Ringing · Audio connected");
    harness.api.phoneCalls.mockRejectedValue(new ApiError(403, "forbidden", "Phone access revoked"));
    fireEvent.focus(window);
    await waitFor(() => expect(harness.disconnect).toHaveBeenCalled());
    expect(phoneMediaIsBusy()).toBe(false);
    expect(screen.queryByRole("region", { name: "Current phone call" })).not.toBeInTheDocument();
    expect(screen.getByLabelText("Phone line")).toHaveTextContent("Unavailable");
  });

  it("clears the retained line when refreshing configuration loses authority", async () => {
    mount();
    await waitFor(() => expect(screen.getByLabelText("Phone line")).toHaveTextContent(configuration.number!.phone_number));
    harness.api.phoneConfiguration.mockRejectedValueOnce(new ApiError(403, "forbidden", "Phone assignment access revoked"));
    fireEvent.focus(window);
    await waitFor(() => expect(screen.getByLabelText("Phone line")).toHaveTextContent("Unavailable"));
    expect(screen.getByLabelText("Phone error")).toHaveTextContent("Phone assignment access revoked");
  });

  it("reconnects audio on the same claimed device without redialing a PSTN leg", async () => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    harness.api.phoneCalls.mockResolvedValue(page([owned]));
    await userEvent.click(answer);
    await screen.findByText("Ringing · Audio connected");
    act(() => { harness.onState?.("disconnected"); });
    await userEvent.click(screen.getByRole("button", { name: "Reconnect phone audio" }));
    await waitFor(() => expect(harness.api.joinPhoneCall).toHaveBeenCalledWith(owned.id));
    await screen.findByText("Ringing · Audio connected");
    expect(harness.api.answerPhoneCall).toHaveBeenCalledOnce();
    expect(harness.api.dialPhone).not.toHaveBeenCalled();
    expect(harness.disconnect).toHaveBeenCalled();
  });

  it.each(["ringing", "answered"] as const)("durably ends an owned %s call once when admission is disabled", async (status) => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    const active = { ...owned, status };
    harness.api.answerPhoneCall.mockResolvedValue({ data: active, credential });
    harness.api.phoneCalls.mockResolvedValue(page([active]));
    await userEvent.click(answer);
    await screen.findByText(`${status === "ringing" ? "Ringing" : "Answered"} · Audio connected`);
    let resolveEnd: (call: PhoneCall) => void = () => undefined;
    harness.api.endPhoneCall.mockImplementation(() => new Promise<PhoneCall>((resolve) => { resolveEnd = resolve; }));
    harness.api.phoneConfiguration.mockResolvedValue({ ...configuration, enabled: false, configured: false });
    fireEvent.focus(window);
    await waitFor(() => expect(harness.api.endPhoneCall).toHaveBeenCalledOnce());
    expect(harness.disconnect).toHaveBeenCalled();
    fireEvent.focus(window);
    await waitFor(() => expect(harness.api.phoneConfiguration).toHaveBeenCalledTimes(3));
    expect(harness.api.endPhoneCall).toHaveBeenCalledOnce();
    await act(async () => { resolveEnd({ ...active, status: "ended", active_on_this_device: false, can_join: false, can_end: false }); });
    await screen.findByText("Ended");
    expect(phoneMediaIsBusy()).toBe(false);
    expect(screen.queryByRole("button", { name: "End call" })).not.toBeInTheDocument();
  });

  it("retains an End retry after disabled admission teardown fails and does not reconnect", async () => {
    mount();
    const answer = await screen.findByRole("button", { name: "Answer" });
    harness.api.phoneCalls.mockResolvedValue(page([owned]));
    await userEvent.click(answer);
    await screen.findByText("Ringing · Audio connected");
    harness.api.phoneConfiguration.mockResolvedValue({ ...configuration, enabled: false, configured: false });
    harness.api.endPhoneCall.mockRejectedValueOnce(new Error("Temporary network failure"));
    fireEvent.focus(window);
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("Hanging up failed. Retry End call."));
    expect(harness.disconnect).toHaveBeenCalled();
    expect(phoneMediaIsBusy()).toBe(true);
    expect(screen.queryByRole("button", { name: "Reconnect phone audio" })).not.toBeInTheDocument();
    const retry = screen.getByRole("button", { name: "End call" });
    expect(retry).toBeEnabled();
    harness.api.phoneCalls.mockResolvedValue(page([]));
    await userEvent.click(retry);
    await screen.findByText("Ended");
    expect(harness.api.endPhoneCall).toHaveBeenCalledTimes(2);
    expect(phoneMediaIsBusy()).toBe(false);
  });

  it("does not end a call owned by another device when admission is disabled", async () => {
    harness.api.phoneCalls.mockResolvedValue(page([{ ...owned, active_on_this_device: false, can_join: false, can_end: false }]));
    mount();
    await waitFor(() => expect(harness.api.phoneCalls).toHaveBeenCalled());
    harness.api.phoneConfiguration.mockResolvedValue({ ...configuration, enabled: false, configured: false });
    fireEvent.focus(window);
    await waitFor(() => expect(harness.api.phoneConfiguration).toHaveBeenCalledTimes(2));
    expect(harness.api.endPhoneCall).not.toHaveBeenCalled();
    expect(harness.connect).not.toHaveBeenCalled();
    expect(phoneMediaIsBusy()).toBe(false);
  });

  it("ends an API reservation that arrives after its owner unmounts", async () => {
    let resolveAnswer: (value: { data: PhoneCall; credential: typeof credential }) => void = () => undefined;
    harness.api.answerPhoneCall.mockImplementation(() => new Promise((resolve) => { resolveAnswer = resolve; }));
    const view = mount();
    await userEvent.click(await screen.findByRole("button", { name: "Answer" }));
    await waitFor(() => expect(harness.api.answerPhoneCall).toHaveBeenCalled());
    view.unmount();
    await act(async () => { resolveAnswer({ data: owned, credential }); });
    expect(harness.connect).not.toHaveBeenCalled();
    expect(harness.api.endPhoneCall).toHaveBeenCalledWith(owned.id);
    expect(phoneMediaIsBusy()).toBe(false);
  });
});
