import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PhonePage } from "./PhonePage";
import type { PhoneCall } from "./types";

const missed: PhoneCall = { id: "missed-1", direction: "inbound", status: "no_answer", from_number: "+14155550199", to_number: "+14155550123", extension: "101", started_at: "2026-10-03T12:00:00Z", answered_at: null, ended_at: "2026-10-03T12:00:30Z", connected_seconds: 0, can_answer: false, can_join: false, can_end: false, active_on_this_device: false };
const harness = vi.hoisted(() => { const calls = vi.fn(); return { api: { phoneCalls: calls }, calls, dial: vi.fn(), configuration: { enabled: true, configured: true, provider: "livekit_sip", number: { id: "line-1", phone_number: "+14155550123", extension: "101", user_id: "user-1" }, can_manage: true }, error: null, conversationBusy: false }; });
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
vi.mock("./TelephonyProvider", () => ({ useTelephony: () => ({ configuration: harness.configuration, loading: false, busy: false, currentCall: null, error: harness.error, conversationBusy: harness.conversationBusy, dial: harness.dial, refresh: vi.fn(), join: vi.fn() }) }));

describe("Phone page", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.configuration.configured = true;
    harness.configuration.enabled = true;
    harness.conversationBusy = false;
    harness.calls.mockResolvedValue({ data: [missed, { ...missed, id: "answered-2", status: "ended", connected_seconds: 47 }], page: { has_more: false, next_cursor: null, limit: 30 } });
  });
  it("shows missed-call outcomes and connected duration then dials only explicit valid international numbers", async () => {
    render(<MemoryRouter><PhonePage /></MemoryRouter>);
    expect(await screen.findByText("Incoming · Missed")).toBeVisible();
    expect(screen.getByText("47s connected")).toBeVisible();
    const button = screen.getByRole("button", { name: "Call number" });
    expect(button).toBeDisabled();
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Phone number"), "+14155550199");
    await user.click(button);
    await waitFor(() => expect(harness.dial).toHaveBeenCalledWith("+14155550199"));
    await user.selectOptions(screen.getByLabelText("Show calls"), "missed");
    await waitFor(() => expect(harness.calls).toHaveBeenLastCalledWith({ limit: 30, cursor: null, scope: "missed" }));
    expect(await screen.findByText("Incoming · Missed")).toBeVisible();
    expect(screen.queryByText("47s connected")).not.toBeInTheDocument();
  });
  it("explains carrier setup and keeps dialing disabled without a configured provider", () => {
    harness.configuration.configured = false;
    render(<MemoryRouter><PhonePage /></MemoryRouter>);
    expect(screen.getByText("A telephony provider must be connected before phone calls are available.")).toBeVisible();
    expect(screen.getByRole("link", { name: "Set up a phone line" })).toHaveAttribute("href", "/admin?section=phone");
    expect(screen.getByRole("button", { name: "Call number" })).toBeDisabled();
  });

  it("shows uncertain answer and duration explicitly rather than presenting a missed call or zero connected time", async () => {
    harness.calls.mockResolvedValue({ data: [{ ...missed, status: "failed", end_reason: "answer_unconfirmed", connected_seconds: 0 }], page: { has_more: false, next_cursor: null, limit: 30 } });
    render(<MemoryRouter><PhonePage /></MemoryRouter>);
    expect(await screen.findByText("Incoming · Answer unconfirmed")).toBeVisible();
    expect(screen.getByText("Duration unconfirmed")).toBeVisible();
    expect(screen.queryByText("0s connected")).not.toBeInTheDocument();
    expect(screen.queryByText("Incoming · Missed")).not.toBeInTheDocument();
    expect(screen.queryByText("Incoming · Failed")).not.toBeInTheDocument();
  });
});
