import { describe, expect, it } from "vitest";
import type { MeetingInput } from "../../types/meetings";
import { dateInTimezone, isIanaTimezone, monthDays, monthQuery, upcomingQuery, validateMeeting } from "./meetingCalendar";

const input: MeetingInput = {
  title: "Review", timezone: "America/New_York", local_start: "2026-10-05T09:30",
  duration_minutes: 30, recurrence: { frequency: "weekly", interval: 1, count: 4 },
  reminder_minutes: 10080, host_policy: { allow_guests: false, join_before_host: false }
};

describe("meeting calendar dates", () => {
  it("uses the calendar time zone for month boundaries across daylight saving changes", () => {
    expect(monthQuery("2026-03", "America/New_York")).toEqual({ from: "2026-03-01T05:00:00.000Z", to: "2026-04-01T04:00:00.000Z" });
    expect(monthQuery("2026-10", "Asia/Kolkata")).toEqual({ from: "2026-09-30T18:30:00.000Z", to: "2026-10-31T18:30:00.000Z" });
    expect(dateInTimezone("2026-10-01T00:00:00Z", "America/Los_Angeles")).toBe("2026-09-30");
  });

  it("keeps ongoing meetings and a cross-month ninety-day agenda inside the server's 93-day limit", () => {
    const now = new Date("2026-12-31T23:59:00Z");
    const query = upcomingQuery(now);
    expect(query.from).toBe("2026-12-31T15:59:00.000Z");
    expect(query.to).toBe("2027-03-31T23:59:00.000Z");
    expect(Date.parse(query.to) - Date.parse(query.from)).toBeLessThan(93 * 86_400_000);
  });

  it("builds a leap-year month with weekday padding", () => {
    const days = monthDays("2028-02");
    expect(days.slice(0, 2)).toEqual([null, null]);
    expect(days.filter(Boolean)).toHaveLength(29);
    expect(days.at(-1)).toBe("2028-02-29");
  });

  it("rejects invalid zones and enforces bounded recurrence, duration, and reminders", () => {
    expect(isIanaTimezone("America/New_York")).toBe(true);
    expect(isIanaTimezone("Not/A_Timezone")).toBe(false);
    expect(isIanaTimezone("+02:00")).toBe(false);
    expect(validateMeeting(input)).toBeNull();
    expect(validateMeeting({ ...input, recurrence: { ...input.recurrence, count: 53 } })).toMatch(/1 to 52/);
    expect(validateMeeting({ ...input, recurrence: { ...input.recurrence, interval: 5 } })).toMatch(/1 to 4/);
    expect(validateMeeting({ ...input, duration_minutes: 481 })).toMatch(/5 to 480/);
    expect(validateMeeting({ ...input, reminder_minutes: 10081 })).toMatch(/10080/);
    expect(validateMeeting({ ...input, reminder_minutes: Number.NaN })).toMatch(/10080/);
  });
});
