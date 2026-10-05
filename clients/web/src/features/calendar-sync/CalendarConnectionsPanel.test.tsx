import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { CalendarConnectionsPanel } from "./CalendarConnectionsPanel";
const harness = vi.hoisted(() => ({ api: { calendarConnections: vi.fn(), authorizeCalendar: vi.fn(), unlinkCalendar: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: { user: { account_type: "human", access_scope: "workspace" } } }) }));
vi.mock("../../app/step-up", () => ({ useStepUp: () => ({ runWithStepUp: <T,>(action: () => Promise<T>) => action() }), stepUpWasCancelled: () => false }));
const response = () => ({ data: [], meta: { mode: "one_way_hosted_occurrences", policy: { export_allowed: true, version: 7 },
  providers: [{ provider: "google", configured: false, qualified: false, safe_reason: "calendar_provider_not_configured" },
    { provider: "microsoft", configured: false, qualified: false, safe_reason: "calendar_provider_not_configured" }] } });
beforeEach(() => { vi.clearAllMocks(); harness.api.calendarConnections.mockResolvedValue(response()); });
function open() { render(<CalendarConnectionsPanel />); const summary = screen.getByText("Connected calendars");
  const details = summary.closest("details")!; details.open = true; fireEvent(details, new Event("toggle")); }
describe("explicit Calendar connection controls", () => {
  it("discloses exact export content and leaves disabled providers unavailable", async () => {
    open(); await screen.findByText("Google Calendar");
    expect(screen.getByText(/title, time, time zone and a member sign-in link/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Connect Google" })).not.toBeInTheDocument();
    expect(harness.api.authorizeCalendar).not.toHaveBeenCalled();
  });
  it("unconfirmed Microsoft grant destruction remains visibly unverified", async () => {
    harness.api.calendarConnections.mockResolvedValue({ ...response(), data: [{ id: "connection", provider: "microsoft", version: 4,
      status: "removed", provider_grant_revocation: "external_unconfirmed", managed_events_pending_removal: 0 }] });
    open(); expect(await screen.findByText(/Microsoft grant revocation is unconfirmed/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Connect Microsoft" })).not.toBeInTheDocument();
  });
});
