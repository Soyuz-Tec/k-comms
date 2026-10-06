import { describe, expect, it, vi } from "vitest";
import type { MeetingInput } from "../../types/meetings";
import type { ApiRequest } from "../contracts";
import { createMeetingsApi } from "./meetings";

const input: MeetingInput = {
  title: "Design review", timezone: "America/New_York", local_start: "2026-10-05T09:30",
  duration_minutes: 30, recurrence: { frequency: "weekly", interval: 1, count: 4 },
  reminder_minutes: 15, host_policy: { allow_guests: false, join_before_host: false }
};

describe("meetings API", () => {
  it("retrieves a meeting through its authenticated detail endpoint", async () => {
    const meeting = { id: "meeting/1", title: "Design review" };
    const request = vi.fn().mockResolvedValue({ data: meeting });
    await expect(createMeetingsApi(request as ApiRequest).getMeeting("meeting/1")).resolves.toBe(meeting);
    expect(request).toHaveBeenCalledWith("/api/v1/meetings/meeting%2F1");
  });

  it("preserves local wall time and includes the optimistic version for updates and cancellation", async () => {
    const request = vi.fn().mockResolvedValue({ data: { id: "meeting-1", version: 2 } });
    const api = createMeetingsApi(request as ApiRequest);
    await api.createMeeting("conversation/1", input);
    await api.updateMeeting("meeting/1", { ...input, expected_version: 1 });
    await api.cancelMeeting("meeting/1", 2);
    expect(request.mock.calls).toEqual([
      ["/api/v1/conversations/conversation%2F1/meetings", { method: "POST", body: JSON.stringify(input) }],
      ["/api/v1/meetings/meeting%2F1", { method: "PATCH", body: JSON.stringify({ ...input, expected_version: 1 }) }],
      ["/api/v1/meetings/meeting%2F1/cancel", { method: "POST", body: JSON.stringify({ expected_version: 2 }) }]
    ]);
  });

  it("requests a bounded calendar window and unwraps authenticated ICS invitations", async () => {
    const ics = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n";
    const request = vi.fn().mockResolvedValueOnce({ data: [] }).mockResolvedValueOnce({ data: { ics, filename: "meeting.ics" } });
    const api = createMeetingsApi(request as ApiRequest);
    const query = { from: "2026-10-01T00:00:00Z", to: "2026-11-01T00:00:00Z" };
    await expect(api.meetings(query)).resolves.toEqual([]);
    await expect(api.meetingCalendar("meeting/1")).resolves.toBe(ics);
    expect(request.mock.calls[0]?.[0]).toBe(`/api/v1/meetings?${new URLSearchParams(query).toString()}`);
    expect(request.mock.calls[1]?.[0]).toBe("/api/v1/meetings/meeting%2F1/calendar");
  });

  it("starts an occurrence through the policy-aware endpoint with encoded identifiers", async () => {
    const response = { data: { id: "call-1" }, credential: { token: "synthetic" } };
    const request = vi.fn().mockResolvedValue(response);
    const api = createMeetingsApi(request as ApiRequest);
    await expect(api.startMeeting("meeting/1", "occurrence/1", "video")).resolves.toEqual(response);
    expect(request).toHaveBeenCalledWith("/api/v1/meetings/meeting%2F1/occurrences/occurrence%2F1/start", { method: "POST", body: JSON.stringify({ media_kind: "video" }) });
  });
  it("retains server truncation evidence for the agenda", async () => {
    const response = { data: [], meta: { truncated: true } };
    const request = vi.fn().mockResolvedValue(response);
    const api = createMeetingsApi(request as ApiRequest);
    await expect(api.meetingsPage({ from: "2026-10-01T00:00:00Z", to: "2026-12-30T00:00:00Z" })).resolves.toEqual(response);
  });

});
