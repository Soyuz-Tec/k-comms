import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Link, MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation } from "../../types";
import type { Meeting } from "../../types/meetings";
import { MeetingsPage } from "./MeetingsPage";

const conversation: Conversation = {
  id: "conversation-1", tenant_id: "tenant-1", title: "Product team", kind: "group", visibility: "private",
  counterpart_user_id: null, counterpart_display_name: null, latest_sequence: 0,
  inserted_at: "2026-10-01T00:00:00Z", updated_at: "2026-10-01T00:00:00Z"
};
const meeting: Meeting = {
  id: "meeting-1", conversation_id: conversation.id, host_user_id: "host-1", title: "Design review",
  timezone: "America/New_York", local_start: "2026-10-04T05:10:00", duration_minutes: 30,
  recurrence: { frequency: "weekly", interval: 1, count: 4 }, reminder_minutes: 15,
  host_policy: { allow_guests: false, join_before_host: false }, version: 3, status: "scheduled", can_manage: true,
  occurrences: [{ id: "occurrence-1", starts_at: "2026-10-04T09:10:00Z", ends_at: "2026-10-04T09:40:00Z", status: "scheduled" }]
};
const harness = vi.hoisted(() => ({
  api: { meetings: vi.fn(), getMeeting: vi.fn(), createMeeting: vi.fn(), updateMeeting: vi.fn(), cancelMeeting: vi.fn(), meetingCalendar: vi.fn() },
  launchCall: vi.fn(), available: true
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: { user: { id: "host-1" }, tenant: { id: "tenant-1" } } }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ conversations: [conversation], capabilities: { allow_video_calls: true, allow_audio_calls: true }, audioCallsAvailable: true, videoCallsAvailable: harness.available, loading: false }) }));
vi.mock("../calls/CallSessionProvider", () => ({ useCallSession: () => ({ launchCall: harness.launchCall }) }));

function renderMeetings(path = "/app/meetings") {
  return render(<MemoryRouter initialEntries={[path]}><MeetingsPage /></MemoryRouter>);
}

describe("MeetingsPage", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-04T09:00:00Z"));
    vi.clearAllMocks();
    harness.available = true;
    harness.api.meetings.mockResolvedValue([meeting]);
    harness.api.getMeeting.mockReset();
    harness.api.createMeeting.mockResolvedValue(meeting);
    harness.api.updateMeeting.mockResolvedValue({ ...meeting, version: 4 });
    harness.api.cancelMeeting.mockResolvedValue({ ...meeting, status: "cancelled", version: 4 });
    harness.api.meetingCalendar.mockResolvedValue("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n");
  });
  afterEach(() => { vi.useRealTimers(); });

  it("shows zoned occurrences and launches the meeting with its policy context", async () => {
    const user = userEvent.setup();
    renderMeetings();
    expect(await screen.findByRole("heading", { name: "Design review" })).toBeVisible();
    expect(screen.getByText(/Product team · America\/New_York/)).toBeVisible();
    expect(screen.getByRole("link", { name: "Open conversation" })).toHaveAttribute("href", "/app/?conversation=conversation-1");
    await user.click(screen.getByRole("button", { name: "Start meeting" }));
    expect(harness.launchCall).toHaveBeenCalledWith(conversation, "video", null, { meetingId: "meeting-1", occurrenceId: "occurrence-1" });
  });

  it("leads with the agenda and focuses the next eligible occurrence without launching it", async () => {
    const user = userEvent.setup();
    const cancelled = { ...meeting, id: "cancelled", title: "Cancelled planning", status: "cancelled" as const, occurrences: [{ ...meeting.occurrences[0]!, id: "cancelled-occurrence", starts_at: "2026-10-04T09:05:00Z" }] };
    const ended = { ...meeting, id: "ended", title: "Earlier review", occurrences: [{ ...meeting.occurrences[0]!, id: "ended-occurrence", starts_at: "2026-10-03T09:10:00Z", ends_at: "2026-10-03T09:40:00Z" }] };
    harness.api.meetings.mockResolvedValue([cancelled, ended, meeting]);
    renderMeetings();
    const row = (await screen.findByRole("heading", { name: "Design review" })).closest("li") as HTMLElement;
    expect(row).toHaveClass("is-next");
    expect(within(row).getByText("Next meeting")).toBeVisible();
    expect(screen.getByText("1 upcoming this month")).toBeVisible();
    expect(screen.getAllByText("Design review")).toHaveLength(1);
    expect(screen.queryByRole("region", { name: "Up next" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Agenda" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.queryByRole("region", { name: /meeting calendar/ })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /^Calendar$/ }));
    const next = screen.getByRole("region", { name: "Up next" });
    expect(next).toHaveTextContent("Design review");
    await user.click(within(next).getByRole("button", { name: "View next meeting" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Design review" }).closest("li")).toHaveFocus());
    expect(screen.queryByRole("region", { name: "Up next" })).not.toBeInTheDocument();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("labels an ongoing scheduled occurrence as in progress while preserving its admission policy", async () => {
    vi.setSystemTime(new Date("2026-10-04T09:20:00Z"));
    renderMeetings();
    const row = (await screen.findByRole("heading", { name: "Design review" })).closest("li") as HTMLElement;
    expect(within(row).getByText("In progress")).toBeVisible();
    expect(screen.getByText("1 in progress · 0 upcoming this month")).toBeVisible();
    expect(screen.queryByRole("region", { name: "In progress" })).not.toBeInTheDocument();
    expect(screen.queryByRole("region", { name: "Up next" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Start meeting" })).toBeEnabled();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it.each([
    { now: "2026-10-04T09:00:00Z", label: "View next meeting", status: "Next meeting" },
    { now: "2026-10-04T09:20:00Z", label: "View current meeting", status: "In progress" }
  ])("keeps a $label jump when earlier rows fill the agenda", async ({ now, label, status }) => {
    vi.setSystemTime(new Date(now));
    const earlier = Array.from({ length: 12 }, (_, index) => ({
      ...meeting,
      id: `earlier-${index}`,
      title: `Earlier review ${index + 1}`,
      occurrences: [{
        ...meeting.occurrences[0]!,
        id: `earlier-occurrence-${index}`,
        starts_at: `2026-10-01T09:${String(index).padStart(2, "0")}:00Z`,
        ends_at: `2026-10-01T09:${String(index + 30).padStart(2, "0")}:00Z`
      }]
    }));
    harness.api.meetings.mockResolvedValue([...earlier, meeting]);
    const user = userEvent.setup();
    renderMeetings();

    const row = (await screen.findByRole("heading", { name: "Design review" })).closest("li") as HTMLElement;
    expect(within(screen.getByRole("list", { name: "Scheduled meetings" })).getAllByRole("listitem")).toHaveLength(13);
    expect(within(row).getByText(status)).toBeVisible();
    expect(screen.getAllByText("Design review")).toHaveLength(1);
    expect(screen.queryByRole("region", { name: "Up next" })).not.toBeInTheDocument();
    expect(screen.queryByRole("region", { name: "In progress" })).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: label }));
    await waitFor(() => expect(row).toHaveFocus());
    expect(screen.getByRole("button", { name: "Agenda" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getAllByText("Design review")).toHaveLength(1);
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("opens an authorized search result in its occurrence month without starting a call", async () => {
    const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const occurrenceId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const selected = { ...meeting, id, title: "December review", occurrences: [{ ...meeting.occurrences[0]!, id: occurrenceId, starts_at: "2026-12-04T09:10:00Z", ends_at: "2026-12-04T09:40:00Z" }] };
    harness.api.getMeeting.mockResolvedValue(selected);
    const user = userEvent.setup();
    renderMeetings(`/app/meetings?meeting=${id}&occurrence=${occurrenceId}`);

    expect(await screen.findByRole("heading", { name: "December review" })).toBeVisible();
    expect(screen.getByLabelText("Month")).toHaveValue("2026-12");
    expect(screen.getByRole("heading", { name: "December review" }).closest("li")).toHaveAttribute("aria-current", "true");
    expect(harness.api.getMeeting).toHaveBeenCalledExactlyOnceWith(id);
    expect(harness.launchCall).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Show all meetings" }));
    await waitFor(() => expect(screen.queryByText(/Selected meeting:/)).not.toBeInTheDocument());
  });

  it.each(["?meeting=foreign/path", "?occurrence=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "?meeting=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&occurrence=invalid"])("rejects malformed meeting references %s before requesting a detail", async query => {
    renderMeetings(`/app/meetings${query}`);
    expect(await screen.findByRole("alert")).toHaveTextContent("This meeting link is incomplete or invalid.");
    expect(harness.api.getMeeting).not.toHaveBeenCalled();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("reports revoked detail access without displaying a selected meeting or starting it", async () => {
    harness.api.getMeeting.mockRejectedValue(new Error("Current conversation membership is required."));
    renderMeetings("/app/meetings?meeting=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    expect(await screen.findByRole("alert")).toHaveTextContent("Current conversation membership is required.");
    expect(screen.queryByText(/Selected meeting:/)).not.toBeInTheDocument();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("rejects a detail response for a different meeting identifier", async () => {
    harness.api.getMeeting.mockResolvedValue({ ...meeting, id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title: "Unexpected detail" });
    renderMeetings("/app/meetings?meeting=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    expect(await screen.findByRole("alert")).toHaveTextContent("The requested meeting could not be verified.");
    expect(screen.queryByText("Unexpected detail")).not.toBeInTheDocument();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("rejects an occurrence outside the selected authorized meeting", async () => {
    const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    harness.api.getMeeting.mockResolvedValue({ ...meeting, id });
    renderMeetings(`/app/meetings?meeting=${id}&occurrence=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`);
    expect(await screen.findByRole("alert")).toHaveTextContent("The selected meeting occurrence is unavailable.");
    expect(screen.queryByText(/Selected meeting:/)).not.toBeInTheDocument();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("discards a delayed detail when navigation selects a different meeting", async () => {
    const oldId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const newId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    let resolveOld: ((value: Meeting) => void) | undefined;
    harness.api.getMeeting.mockImplementation((id: string) => id === oldId
      ? new Promise<Meeting>(resolve => { resolveOld = resolve; })
      : Promise.resolve({ ...meeting, id: newId, title: "Current selected meeting" }));
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={[`/app/meetings?meeting=${oldId}`]}><Link to={`/app/meetings?meeting=${newId}`}>Select another meeting</Link><MeetingsPage /></MemoryRouter>);
    await waitFor(() => expect(harness.api.getMeeting).toHaveBeenCalledWith(oldId));
    await user.click(screen.getByRole("link", { name: "Select another meeting" }));
    expect(await screen.findByRole("heading", { name: "Current selected meeting" })).toBeVisible();
    await act(async () => { resolveOld?.({ ...meeting, id: oldId, title: "Stale selected meeting" }); });
    await waitFor(() => expect(screen.queryByText("Stale selected meeting")).not.toBeInTheDocument());
    expect(screen.getByRole("heading", { name: "Current selected meeting" })).toBeVisible();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("schedules local wall time, recurrence, reminders, and host policy without UTC conversion", async () => {
    const user = userEvent.setup();
    renderMeetings();
    await screen.findByRole("heading", { name: "Design review" });
    await user.click(screen.getByRole("button", { name: "Schedule meeting" }));
    const dialog = screen.getByRole("dialog", { name: "Schedule meeting" });
    await user.type(within(dialog).getByLabelText("Title"), "Planning");
    await user.selectOptions(within(dialog).getByRole("combobox", { name: /^Conversation$/ }), conversation.id);
    fireEvent.change(within(dialog).getByLabelText("Local start date and time"), { target: { value: "2026-10-07T10:00" } });
    const zone = within(dialog).getByRole("combobox", { name: /^Time zone$/ });
    await user.clear(zone);
    await user.type(zone, "Asia/Kolkata");
    await user.selectOptions(within(dialog).getByRole("combobox", { name: /^Repeat$/ }), "weekly");
    fireEvent.change(within(dialog).getByLabelText("Number of occurrences"), { target: { value: "6" } });
    await user.click(within(dialog).getByLabelText("Allow guests"));
    await user.click(within(dialog).getByRole("button", { name: "Schedule meeting" }));
    await waitFor(() => expect(harness.api.createMeeting).toHaveBeenCalledWith(conversation.id, expect.objectContaining({ title: "Planning", timezone: "Asia/Kolkata", local_start: "2026-10-07T10:00", recurrence: { frequency: "weekly", interval: 1, count: 6 }, reminder_minutes: 15, host_policy: { allow_guests: true, join_before_host: false } })));
    expect(await screen.findByText("Meeting scheduled.")).toBeVisible();
  });

  it("opens an audio meeting lobby when video calling is unavailable", async () => {
    harness.available = false;
    const user = userEvent.setup();
    renderMeetings();
    await user.click(await screen.findByRole("button", { name: "Start meeting" }));
    expect(harness.launchCall).toHaveBeenCalledWith(conversation, "audio", null, { meetingId: "meeting-1", occurrenceId: "occurrence-1" });
  });

  it("updates and cancels the whole series with its version", async () => {
    const user = userEvent.setup();
    renderMeetings();
    await user.click(await screen.findByRole("button", { name: "Edit series" }));
    const dialog = screen.getByRole("dialog", { name: "Edit meeting" });
    const title = within(dialog).getByLabelText("Title");
    await user.clear(title);
    await user.type(title, "Revised review");
    await user.click(within(dialog).getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(harness.api.updateMeeting).toHaveBeenCalledWith("meeting-1", expect.objectContaining({ title: "Revised review", expected_version: 3 })));
    await user.click(await screen.findByRole("button", { name: "Cancel series" }));
    const confirmation = screen.getByRole("alertdialog", { name: "Cancel meeting?" });
    expect(confirmation).toHaveTextContent("every occurrence in this series");
    await user.click(within(confirmation).getByRole("button", { name: "Cancel meeting" }));
    await waitFor(() => expect(harness.api.cancelMeeting).toHaveBeenCalledWith("meeting-1", 3));
  });

  it("keeps failed edits open and does not silently overwrite a stale version", async () => {
    harness.api.updateMeeting.mockRejectedValue(new Error("Meeting changed. Refresh before updating."));
    const user = userEvent.setup();
    renderMeetings();
    await user.click(await screen.findByRole("button", { name: "Edit series" }));
    const dialog = screen.getByRole("dialog", { name: "Edit meeting" });
    await user.click(within(dialog).getByRole("button", { name: "Save changes" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Meeting changed");
    expect(dialog).toBeVisible();
    expect(harness.api.updateMeeting).toHaveBeenCalledTimes(1);
  });

  it("filters the calendar by selected day and preserves the list view", async () => {
    const user = userEvent.setup();
    renderMeetings();
    await screen.findByRole("heading", { name: "Design review" });
    await user.click(screen.getByRole("button", { name: /^Calendar$/ }));
    await user.click(screen.getByRole("button", { name: /2026-10-06, 0 meetings/ }));
    expect(screen.getByText("No meetings on this day.")).toBeVisible();
    await user.click(within(screen.getByRole("region", { name: "Up next" })).getByRole("button", { name: "View next meeting" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Design review" }).closest("li")).toHaveFocus());
    expect(screen.queryByText("No meetings on this day.")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^Agenda$/ })).toHaveAttribute("aria-pressed", "true");
  });

  it("offers retry after a calendar request fails", async () => {
    harness.api.meetings.mockRejectedValueOnce(new Error("Calendar unavailable")).mockResolvedValue([meeting]);
    const user = userEvent.setup();
    renderMeetings();
    expect(await screen.findByRole("alert")).toHaveTextContent("Calendar unavailable");
    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("heading", { name: "Design review" })).toBeVisible();
    expect(harness.api.meetings).toHaveBeenCalledTimes(2);
  });

  it("reports invitation download failure without removing the scheduled meeting", async () => {
    harness.api.meetingCalendar.mockRejectedValue(new Error("Invitation unavailable"));
    const user = userEvent.setup();
    renderMeetings();
    await user.click(await screen.findByRole("button", { name: "Download invitation" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Invitation unavailable");
    expect(screen.getByRole("heading", { name: "Design review" })).toBeVisible();
    expect(harness.api.meetingCalendar).toHaveBeenCalledWith("meeting-1");
  });
});
