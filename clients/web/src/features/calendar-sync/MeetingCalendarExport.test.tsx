import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { Meeting } from "../../types/meetings";
import { MeetingCalendarExport } from "./MeetingCalendarExport";

const harness = vi.hoisted(() => ({ api: { calendarConnections: vi.fn(), calendarExports: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp: <T,>(action: () => Promise<T>) => action() }),
  stepUpWasCancelled: () => false
}));

const meeting: Meeting = {
  id: "meeting-1", conversation_id: "conversation-1", host_user_id: "host-1", title: "Design review",
  timezone: "UTC", local_start: "2026-10-04T09:10:00", duration_minutes: 30,
  recurrence: { frequency: "none", interval: 1, count: 1 }, reminder_minutes: 15,
  host_policy: { allow_guests: false, join_before_host: false }, version: 3, status: "scheduled", can_manage: true,
  occurrences: []
};

describe("MeetingCalendarExport", () => {
  it("takes a host without a connected calendar directly to calendar settings", async () => {
    harness.api.calendarConnections.mockResolvedValue({ data: [] });
    harness.api.calendarExports.mockResolvedValue({ data: [] });
    render(<MemoryRouter><MeetingCalendarExport meeting={meeting} /></MemoryRouter>);
    expect(harness.api.calendarConnections).not.toHaveBeenCalled();

    const details = screen.getByText("External calendar export").closest("details")!;
    details.open = true;
    fireEvent(details, new Event("toggle"));

    expect(await screen.findByRole("link", { name: "Connected calendars" })).toHaveAttribute("href", "/app/you?section=calendar");
    expect(harness.api.calendarExports).toHaveBeenCalledWith("meeting-1");
    expect(screen.queryByRole("button", { name: /^Export to/ })).not.toBeInTheDocument();
  });
});
