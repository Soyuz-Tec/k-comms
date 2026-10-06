import type { Meeting, MeetingInput, MeetingsQuery } from "../../types/meetings";

export function systemTimezone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

export function isIanaTimezone(value: string): boolean {
  if (!value || /^[+-]/.test(value)) return false;
  try {
    new Intl.DateTimeFormat("en", { timeZone: value });
    return true;
  } catch {
    return false;
  }
}

export function dateInTimezone(instant: string, timezone: string): string {
  const parts = new Intl.DateTimeFormat("en", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit"
  }).formatToParts(new Date(instant));
  const part = (name: string) => parts.find((entry) => entry.type === name)?.value || "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

function monthBoundary(year: number, month: number, timezone: string): Date {
  // Resolve midnight in the calendar zone rather than the browser's UTC offset.
  const wall = Date.UTC(year, month, 1);
  let candidate = wall;
  const formatter = new Intl.DateTimeFormat("en", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23"
  });
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const parts = formatter.formatToParts(new Date(candidate));
    const value = (name: string) => Number(parts.find((entry) => entry.type === name)?.value || 0);
    const observed = Date.UTC(value("year"), value("month") - 1, value("day"), value("hour"), value("minute"), value("second"));
    const adjustment = wall - observed;
    if (!adjustment) break;
    candidate += adjustment;
  }
  return new Date(candidate);
}

export function monthQuery(month: string, timezone: string): MeetingsQuery {
  const [yearValue, monthValue] = month.split("-").map(Number);
  if (!yearValue || !monthValue || monthValue > 12 || !isIanaTimezone(timezone)) {
    throw new Error("Choose a valid calendar month and time zone.");
  }
  return {
    from: monthBoundary(yearValue, monthValue - 1, timezone).toISOString(),
    to: monthBoundary(yearValue, monthValue, timezone).toISOString()
  };
}

export function monthDays(month: string): (string | null)[] {
  const [year = 0, monthNumber = 0] = month.split("-").map(Number);
  const first = new Date(Date.UTC(year, monthNumber - 1, 1));
  const total = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
  return [
    ...Array.from({ length: first.getUTCDay() }, () => null),
    ...Array.from({ length: total }, (_, index) => `${month}-${String(index + 1).padStart(2, "0")}`)
  ];
}

export function meetingInput(meeting: Meeting): MeetingInput {
  return {
    title: meeting.title,
    timezone: meeting.timezone,
    local_start: meeting.local_start.slice(0, 16),
    duration_minutes: meeting.duration_minutes,
    recurrence: { ...meeting.recurrence },
    reminder_minutes: meeting.reminder_minutes,
    host_policy: { ...meeting.host_policy }
  };
}

export function validateMeeting(input: MeetingInput): string | null {
  if (!input.title.trim() || input.title.trim().length > 200) return "Enter a title of 1 to 200 characters.";
  if (!isIanaTimezone(input.timezone)) return "Enter an IANA time zone, such as America/New_York.";
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(input.local_start)) return "Choose the local start date and time.";
  if (!Number.isInteger(input.duration_minutes) || input.duration_minutes < 5 || input.duration_minutes > 480) return "Duration must be 5 to 480 minutes.";
  if (!Number.isInteger(input.recurrence.interval) || input.recurrence.interval < 1 || input.recurrence.interval > 4) return "Repeat interval must be 1 to 4.";
  if (!Number.isInteger(input.recurrence.count) || input.recurrence.count < 1 || input.recurrence.count > 52) return "Repeat count must be 1 to 52.";
  if (!Number.isInteger(input.reminder_minutes) || input.reminder_minutes < 0 || input.reminder_minutes > 10080) return "Reminder must be between 0 and 10080 minutes before the meeting.";
  return null;
}

/** Include an ongoing meeting up to the supported eight-hour duration. */
export function upcomingQuery(now = new Date()): MeetingsQuery {
  return {
    from: new Date(now.getTime() - 8 * 60 * 60_000).toISOString(),
    to: new Date(now.getTime() + 90 * 24 * 60 * 60_000).toISOString()
  };
}
