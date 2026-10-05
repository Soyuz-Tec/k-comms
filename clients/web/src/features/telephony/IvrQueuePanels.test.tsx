import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/errors";
import { IvrAdminPanel } from "./IvrAdminPanel";
import { AgentQueuePanel } from "./AgentQueuePanel";
import { QueueSupervisorPanel } from "./QueueSupervisorPanel";
import type { IvrMenu } from "./ivrTypes";

const harness = vi.hoisted(() => ({ api: {
  phoneIvrConfiguration: vi.fn(), phoneRoutes: vi.fn(), voicemailMailbox: vi.fn(), savePhoneIvr: vi.fn(),
  phoneAgentState: vi.fn(), setPhoneAgentState: vi.fn(), phoneQueueSnapshot: vi.fn()
}, stepUp: vi.fn() }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
vi.mock("../../app/step-up", () => ({ useStepUp: () => ({ runWithStepUp: harness.stepUp }), stepUpWasCancelled: () => false }));

const menu: IvrMenu = { id: "menu-1", name: "Support", prompt_media: "sound:custom/menu", choices: { "1": { kind: "hangup" } }, fallback: { kind: "hangup" }, digit_timeout_seconds: 10, max_retries: 1, enabled: false, version: 7 };
const ready = { state: "ready", expires_at: null, explicit: false, version: 0, online_presence_observed: false };

describe("caller menu and current queue controls", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.api.phoneIvrConfiguration.mockResolvedValue({ menu, available: false, max_active_callers: 100, approved_prompts: [] });
    harness.api.phoneRoutes.mockResolvedValue({ data: [], limit: 100 });
    harness.api.voicemailMailbox.mockResolvedValue(null);
    harness.api.phoneAgentState.mockResolvedValue(ready);
    harness.stepUp.mockImplementation((action: () => Promise<unknown>) => action());
  });
  it("keeps enablement closed while saving a disabled menu through current verification", async () => {
    harness.api.savePhoneIvr.mockResolvedValue({ ...menu, version: 8 });
    render(<IvrAdminPanel />);
    expect(await screen.findByLabelText("Menu name")).toHaveValue("Support");
    expect(screen.getByLabelText("Enable caller menu")).toBeDisabled();
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Caller menu change reason"), "Review disabled menu");
    await user.click(screen.getByRole("button", { name: "Save caller menu" }));
    expect(await screen.findByText("Caller menu saved.")).toBeVisible();
    expect(harness.stepUp).toHaveBeenCalledOnce();
    expect(harness.api.savePhoneIvr).toHaveBeenCalledWith({ name: "Support", prompt_media: "sound:custom/menu", choices: menu.choices, fallback: menu.fallback, digit_timeout_seconds: 10, max_retries: 1, enabled: false, version: 7, reason: "Review disabled menu" });
  });
  it("preserves a stale menu draft and prevents retry until the saved version is explicitly reloaded", async () => {
    harness.api.savePhoneIvr.mockRejectedValue(new ApiError(409, "stale_version", "Changed"));
    render(<IvrAdminPanel />);
    const user = userEvent.setup();
    await user.clear(await screen.findByLabelText("Menu name"));
    await user.type(screen.getByLabelText("Menu name"), "Unsaved support menu");
    await user.type(screen.getByLabelText("Caller menu change reason"), "Keep this draft");
    await user.click(screen.getByRole("button", { name: "Save caller menu" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Your draft is preserved");
    expect(screen.getByLabelText("Menu name")).toHaveValue("Unsaved support menu");
    expect(screen.getByRole("button", { name: "Save caller menu" })).toBeDisabled();
    expect(harness.api.savePhoneIvr).toHaveBeenCalledOnce();
    expect(harness.api.phoneIvrConfiguration).toHaveBeenCalledOnce();
    harness.api.phoneIvrConfiguration.mockResolvedValue({ menu: { ...menu, name: "Current menu", version: 8 }, available: false, approved_prompts: [], max_active_callers: 100 });
    await user.click(screen.getByRole("button", { name: "Reload saved caller menu" }));
    await waitFor(() => expect(screen.getByLabelText("Menu name")).toHaveValue("Current menu"));
    expect(screen.getByRole("button", { name: "Save caller menu" })).toBeEnabled();
  });
  it("hides personal state for an unassigned member without claiming eligibility", async () => {
    harness.api.phoneAgentState.mockRejectedValue(new ApiError(403, "telephony_agent_not_assigned", "Not assigned"));
    render(<AgentQueuePanel />);
    await waitFor(() => expect(screen.queryByRole("heading", { name: "Your queue availability" })).not.toBeInTheDocument());
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(harness.api.setPhoneAgentState).not.toHaveBeenCalled();
  });
  it("uses own retained state version and requires refresh after a stale write", async () => {
    harness.api.setPhoneAgentState.mockRejectedValue(new ApiError(409, "stale_version", "Changed"));
    render(<AgentQueuePanel />);
    expect(await screen.findByText("Ready")).toBeVisible();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Set Away" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Refresh it before choosing another state");
    expect(harness.api.setPhoneAgentState).toHaveBeenCalledWith({ state: "away", duration_seconds: 300, version: 0 });
    expect(screen.getByRole("button", { name: "Set Ready" })).toBeDisabled();
    expect(harness.stepUp).not.toHaveBeenCalled();
    expect(harness.api.phoneAgentState).toHaveBeenCalledOnce();
  });
  it("loads aggregate supervisor data only on explicit verified action", async () => {
    harness.api.phoneQueueSnapshot.mockResolvedValue({ routes: [{ id: "route-1", name: "Support", enabled: true, configured_members: 3, max_waiting: 10, waiting_calls: 2, offered_calls: 1, answered_calls: 4, oldest_observed_wait_seconds: 12 }], observed_at: "2026-10-05T12:00:00Z", coverage: "current_retained_calls", online_presence_observed: false, historical_service_level_available: false, oldest_wait_basis: "call_started_at" });
    render(<QueueSupervisorPanel />);
    expect(harness.api.phoneQueueSnapshot).not.toHaveBeenCalled();
    await userEvent.setup().click(screen.getByRole("button", { name: "Load current queues" }));
    expect(await screen.findByRole("table")).toHaveTextContent("Support");
    expect(screen.getByRole("table")).toHaveTextContent("2 / 10");
    expect(screen.getByRole("table")).toHaveTextContent("12s");
    expect(harness.stepUp).toHaveBeenCalledOnce();
    expect(screen.getByText(/Counts do not show online agents or historical service levels/)).toBeVisible();
  });
});
