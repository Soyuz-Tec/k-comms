import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PhonePage } from "./PhonePage";
import type { PhoneCall, PhoneConfiguration } from "./types";
import type { Session } from "../../types";

const missed: PhoneCall = { id: "missed-1", direction: "inbound", status: "no_answer", from_number: "+14155550199", to_number: "+14155550123", extension: "101", started_at: "2026-10-03T12:00:00Z", answered_at: null, ended_at: "2026-10-03T12:00:30Z", connected_seconds: 0, can_answer: false, can_join: false, can_end: false, active_on_this_device: false };
const harness = vi.hoisted(() => { const calls = vi.fn(); return { api: { phoneCalls: calls, voicemails: vi.fn().mockResolvedValue({ data: [], configured: false, page: { has_more: false, next_cursor: null, limit: 30 } }) }, session: null as Session | null, calls, dial: vi.fn(), refresh: vi.fn(), configuration: null as PhoneConfiguration | null, loading: false, error: null as string | null, conversationBusy: false }; });
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: harness.session }) }));
vi.mock("./AgentQueuePanel", () => ({ AgentQueuePanel: () => null }));
vi.mock("./TelephonyProvider", () => ({ useTelephony: () => ({ configuration: harness.configuration, loading: harness.loading, busy: false, currentCall: null, error: harness.error, conversationBusy: harness.conversationBusy, dial: harness.dial, refresh: harness.refresh, join: vi.fn() }) }));

function renderPhone() { return render(<MemoryRouter><PhonePage /></MemoryRouter>); }
function session(userId: string): Session {
  return { access_token: "synthetic", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900, tenant: { id: "tenant-1", name: "Synthetic", slug: "synthetic", status: "active" }, user: { id: userId, tenant_id: "tenant-1", display_name: userId, status: "active", role: "member", access_scope: "workspace" }, device: { id: "device-1", user_id: userId, name: "Browser", platform: "web" } };
}

describe("Phone page", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.session = session("user-1");
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

  it("marks Phone active and returns to internet calls without dialing", async () => {
    render(<MemoryRouter initialEntries={["/app/calls/phone"]}>
      <Routes>
        <Route path="/app/calls/phone" element={<PhonePage />} />
        <Route path="/app/calls" element={<h1>Internet calls destination</h1>} />
      </Routes>
    </MemoryRouter>);
    await screen.findByText("Incoming · Missed");

    const callTypes = screen.getByRole("navigation", { name: "Call types" });
    expect(within(callTypes).getAllByRole("link")).toHaveLength(2);
    expect(within(callTypes).getByRole("link", { name: "Phone" })).toHaveAttribute("aria-current", "page");
    expect(within(callTypes).getByRole("link", { name: "Phone" })).toHaveAttribute("href", "/app/calls/phone");
    const internetCalls = within(callTypes).getByRole("link", { name: "Internet calls" });
    expect(internetCalls).not.toHaveAttribute("aria-current");
    await userEvent.setup().click(internetCalls);

    expect(screen.getByRole("heading", { name: "Internet calls destination" })).toBeVisible();
    expect(harness.dial).not.toHaveBeenCalled();
  });

  it("normalizes a formatted international number only on an explicit call and rejects extension suffixes", async () => {
    renderPhone();
    await screen.findByText("Incoming · Missed");
    const user = userEvent.setup();
    const number = screen.getByLabelText("Phone number");
    await user.type(number, "+1 (415) 555-0199");
    expect(harness.dial).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Call number" }));
    expect(harness.dial).toHaveBeenCalledWith("+14155550199");
    await user.type(number, " ext 101");
    expect(screen.getByRole("button", { name: "Call number" })).toBeDisabled();
    expect(screen.getByRole("link", { name: "Find a person for an Internet call" })).toHaveAttribute("href", "/app/directory");
  });

  it("searches retained history by number, direction and UTC dates and carries filters to the next page", async () => {
    renderPhone();
    await screen.findByText("Incoming · Missed");
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Search phone history"), "0199");
    await user.click(screen.getByText("Date and direction"));
    await user.selectOptions(screen.getByLabelText("Direction"), "inbound");
    fireEvent.change(screen.getByLabelText("From (UTC)"), { target: { value: "2026-10-01" } });
    fireEvent.change(screen.getByLabelText("To (UTC)"), { target: { value: "2026-10-05" } });
    harness.calls.mockResolvedValueOnce({ data: [missed], page: { has_more: true, next_cursor: "matched-older", limit: 30 } });
    await user.click(screen.getByRole("button", { name: "Search history" }));
    const expected = { limit: 30, cursor: null, scope: undefined, q: "0199", direction: "inbound", from: "2026-10-01", to: "2026-10-05" };
    await waitFor(() => expect(harness.calls).toHaveBeenLastCalledWith(expected));
    await user.click(await screen.findByRole("button", { name: "Load more phone calls" }));
    expect(harness.calls).toHaveBeenLastCalledWith({ ...expected, cursor: "matched-older" });
    await user.click(screen.getByRole("button", { name: "Clear search filters" }));
    await waitFor(() => expect(harness.calls).toHaveBeenLastCalledWith({ limit: 30, cursor: null, scope: undefined }));
  });

  it("prepares a voicemail callback for review without bypassing calling availability", async () => {
    harness.api.voicemails.mockResolvedValueOnce({ data: [{ id: "voice", call_id: "missed-1", caller_number: "+14155550199", status: "available", inserted_at: missed.started_at, retention_expires_at: "2026-11-03T12:00:00Z", read_at: null }], configured: true, page: { has_more: false, next_cursor: null, limit: 30 } });
    harness.configuration = { ...harness.configuration!, configured: false, enabled: false };
    renderPhone();
    await userEvent.setup().click(await screen.findByRole("button", { name: "Return call" }));
    expect(screen.getByLabelText("Phone number")).toHaveValue("+14155550199");
    expect(screen.getByLabelText("Phone number")).toHaveFocus();
    expect(screen.getByRole("button", { name: "Call number" })).toBeDisabled();
    expect(harness.dial).not.toHaveBeenCalled();
    expect(screen.getByText(/Review it, then choose Call number/)).toBeVisible();
  });

  it("clears retained caller data when history authority is withdrawn", async () => {
    renderPhone();
    await screen.findByText("Incoming · Missed");
    await userEvent.setup().click(screen.getAllByRole("button", { name: "Use number" })[0]!);
    harness.calls.mockRejectedValueOnce(Object.assign(new Error("History access withdrawn"), { status: 403 }));
    await userEvent.setup().click(screen.getByRole("button", { name: "Refresh phone calls" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("History access withdrawn");
    expect(screen.queryByText("+14155550199")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Phone number")).toHaveValue("");
  });

  it.each(["user", "token", "scope"])("rejects old history arriving after a same-client %s change", async (change) => {
    let resolveOld!: (value: unknown) => void;
    harness.calls.mockReturnValueOnce(new Promise(resolve => { resolveOld = resolve; }));
    const mounted = renderPhone();
    harness.calls.mockResolvedValueOnce({ data: [], page: { has_more: false, next_cursor: null, limit: 30 } });
    harness.session = change === "user" ? session("user-2") : change === "token" ? { ...session("user-1"), access_token: "new-synthetic-token" } : { ...session("user-1"), user: { ...session("user-1").user, access_scope: "conversation_only" } };
    mounted.rerender(<MemoryRouter><PhonePage /></MemoryRouter>);
    await screen.findByText("No phone calls yet.");
    resolveOld({ data: [missed], page: { has_more: false, next_cursor: null, limit: 30 } });
    await waitFor(() => expect(screen.queryByText("Incoming · Missed")).not.toBeInTheDocument());
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
    const callTypes = screen.getByRole("navigation", { name: "Call types" });
    expect(within(callTypes).getByRole("link", { name: "Internet calls" })).toHaveAttribute("href", "/app/calls");
    expect(within(callTypes).queryByRole("link", { name: /setup|admin/i })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Review phone setup" })).toHaveAttribute("href", "/admin?section=phone");
    if (!readiness.enabled) {
      expect(screen.getByText(/Review line assignments in Phone administration/)).toBeVisible();
      expect(screen.queryByText(/line assignment below/)).not.toBeInTheDocument();
    }
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
    await user.click(screen.getByText("About this keypad"));
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
