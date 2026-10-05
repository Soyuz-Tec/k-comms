import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PhonePage } from "./PhonePage";
import type { PhoneCall, PhoneConfiguration } from "./types";

const missed: PhoneCall = { id: "missed-1", direction: "inbound", status: "no_answer", from_number: "+14155550199", to_number: "+14155550123", extension: "101", started_at: "2026-10-03T12:00:00Z", answered_at: null, ended_at: "2026-10-03T12:00:30Z", connected_seconds: 0, can_answer: false, can_join: false, can_end: false, active_on_this_device: false };
const harness = vi.hoisted(() => { const calls = vi.fn(); return { api: { phoneCalls: calls, voicemails: vi.fn().mockResolvedValue({ data: [], configured: false, page: { has_more: false, next_cursor: null, limit: 30 } }) }, calls, dial: vi.fn(), refresh: vi.fn(), configuration: null as PhoneConfiguration | null, loading: false, error: null as string | null, conversationBusy: false }; });
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
vi.mock("./TelephonyProvider", () => ({ useTelephony: () => ({ configuration: harness.configuration, loading: harness.loading, busy: false, currentCall: null, error: harness.error, conversationBusy: harness.conversationBusy, dial: harness.dial, refresh: harness.refresh, join: vi.fn() }) }));

function renderPhone() { return render(<MemoryRouter><PhonePage /></MemoryRouter>); }

describe("Phone page", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.configuration = { enabled: true, configured: true, provider_ready: true, line_assigned: true, provider: "livekit_sip", number: { id: "line-1", phone_number: "+14155550123", extension: "101", user_id: "user-1" }, can_manage: true };
    harness.loading = false;
    harness.error = null;
    harness.conversationBusy = false;
    harness.calls.mockResolvedValue({ data: [missed, { ...missed, id: "answered-2", status: "ended", connected_seconds: 47 }], page: { has_more: false, next_cursor: null, limit: 30 } });
  });
  it("shows missed-call outcomes and connected duration then dials only explicit valid international numbers", async () => {
    renderPhone();
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

  it.each([
    { enabled: false, provider_ready: false, line_assigned: false, title: "Phone service is off" },
    { enabled: true, provider_ready: false, line_assigned: false, title: "Phone provider needs setup" },
    { enabled: true, provider_ready: true, line_assigned: false, title: "No phone line assigned" }
  ])("loads and refreshes history while explaining $title", async ({ title, ...readiness }) => {
    harness.configuration = { ...harness.configuration!, ...readiness, configured: false, number: null };
    renderPhone();
    expect(screen.getByRole("heading", { name: title })).toBeVisible();
    expect(await screen.findByText("Incoming · Missed")).toBeVisible();
    expect(screen.getByRole("button", { name: "Call number" })).toBeDisabled();
    expect(screen.getByRole("link", { name: "Review phone setup" })).toHaveAttribute("href", "/admin?section=phone");
    await userEvent.setup().click(screen.getByRole("button", { name: "Refresh phone calls" }));
    await waitFor(() => expect(harness.calls).toHaveBeenCalledTimes(2));
    expect(harness.dial).not.toHaveBeenCalled();
  });

  it("gives an unassigned member an administrator next step without suggesting disconnected provider setup", async () => {
    harness.configuration = { ...harness.configuration!, configured: false, line_assigned: false, number: null, can_manage: false };
    renderPhone();
    expect(screen.getByText("Ask your workspace administrator to assign you a phone number and extension.")).toBeVisible();
    expect(screen.queryByRole("link", { name: "Review phone setup" })).not.toBeInTheDocument();
    expect(screen.queryByText(/provider needs setup/i)).not.toBeInTheDocument();
    expect(await screen.findByText("Incoming · Missed")).toBeVisible();
    await userEvent.setup().click(screen.getByRole("button", { name: "Refresh phone availability" }));
    expect(harness.refresh).toHaveBeenCalledOnce();
  });

  it("loads history even while phone configuration is still being checked", async () => {
    harness.configuration = null;
    harness.loading = true;
    renderPhone();
    expect(screen.getByText("Checking phone availability…")).toBeVisible();
    expect(await screen.findByText("Incoming · Missed")).toBeVisible();
  });

  it("paginates personal history while the service is off and no line is assigned", async () => {
    harness.configuration = { ...harness.configuration!, enabled: false, configured: false, number: null, line_assigned: false };
    harness.calls.mockResolvedValueOnce({ data: [missed], page: { has_more: true, next_cursor: "older-page", limit: 30 } });
    harness.calls.mockResolvedValueOnce({ data: [{ ...missed, id: "older-answered", status: "ended", connected_seconds: 47 }], page: { has_more: false, next_cursor: null, limit: 30 } });
    renderPhone();
    await userEvent.setup().click(await screen.findByRole("button", { name: "Load more phone calls" }));
    expect(await screen.findByText("47s connected")).toBeVisible();
    expect(screen.getByText("Incoming · Missed")).toBeVisible();
    expect(harness.calls).toHaveBeenLastCalledWith({ limit: 30, cursor: "older-page", scope: undefined });
  });

  it("shows a retryable history error instead of a false empty-history message", async () => {
    harness.calls.mockRejectedValueOnce(new Error("History could not be loaded"));
    renderPhone();
    expect(await screen.findByRole("alert")).toHaveTextContent("History could not be loaded");
    expect(screen.queryByText("No phone calls yet.")).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Refresh phone calls" }));
    expect(await screen.findByText("Incoming · Missed")).toBeVisible();
  });

  it("uses the keypad only to edit the destination before an explicit call", async () => {
    renderPhone();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Enter country code prefix" }));
    await user.click(screen.getByRole("button", { name: "Enter 1" }));
    await user.click(screen.getByRole("button", { name: "Enter 4" }));
    expect(screen.getByLabelText("Phone number")).toHaveValue("+14");
    await user.click(screen.getByRole("button", { name: "Delete last digit" }));
    expect(screen.getByLabelText("Phone number")).toHaveValue("+1");
    expect(screen.getByText(/does not send tones during a call/)).toBeVisible();
    expect(harness.dial).not.toHaveBeenCalled();
  });

  it("shows uncertain answer and duration explicitly rather than presenting a missed call or zero connected time", async () => {
    harness.calls.mockResolvedValue({ data: [{ ...missed, status: "failed", end_reason: "answer_unconfirmed", connected_seconds: 0 }], page: { has_more: false, next_cursor: null, limit: 30 } });
    renderPhone();
    expect(await screen.findByText("Incoming · Answer unconfirmed")).toBeVisible();
    expect(screen.getByText("Duration unconfirmed")).toBeVisible();
    expect(screen.queryByText("0s connected")).not.toBeInTheDocument();
    expect(screen.queryByText("Incoming · Missed")).not.toBeInTheDocument();
    expect(screen.queryByText("Incoming · Failed")).not.toBeInTheDocument();
  });
});
