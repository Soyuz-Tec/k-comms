import type { Availability } from "../../types/enterpriseIdentity";

export class InvalidAvailabilityResponse extends Error {
  constructor() {
    super("Availability could not be verified. Retry to check your current status.");
    this.name = "InvalidAvailabilityResponse";
  }
}

const states = new Set(["available", "away", "busy", "dnd", "offline"]);
const clockTime = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
const instant = /^(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/;
const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
function deadline(value: unknown) {
  if (value === null) return true;
  if (typeof value !== "string") return false;
  const parts = instant.exec(value);
  if (!parts) return false;
  const year = Number(parts[1]);
  const days = [31, year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return Number(parts[3]) <= (days[Number(parts[2]) - 1] ?? 0) && Number.isFinite(Date.parse(value));
}

function validSchedule(value: unknown) {
  if (!record(value)) return false;
  const keys = Object.keys(value);
  if (!keys.length) return true;
  return keys.length === 3 && keys.every((key) => ["days", "start", "end"].includes(key)) &&
    Array.isArray(value.days) && value.days.length > 0 && value.days.length <= 7 &&
    value.days.every((day) => Number.isInteger(day) && day >= 1 && day <= 7) &&
    new Set(value.days).size === value.days.length &&
    typeof value.start === "string" && clockTime.test(value.start) &&
    typeof value.end === "string" && clockTime.test(value.end) && value.start !== value.end;
}

// API types do not validate a successful response at runtime. Never invent a
// status or weekly policy when the server response cannot establish them.
export function readAvailability(value: unknown): Availability {
  if (!record(value) ||
    typeof value.status !== "string" || !states.has(value.status) ||
    typeof value.presence_state !== "string" || !states.has(value.presence_state) ||
    typeof value.dnd_active !== "boolean" ||
    !deadline(value.presence_expires_at) || !deadline(value.dnd_until) || !deadline(value.retry_at) ||
    !validSchedule(value.dnd_schedule) ||
    typeof value.timezone !== "string" || !value.timezone.trim() || value.timezone.length > 100) {
    throw new InvalidAvailabilityResponse();
  }
  return value as unknown as Availability;
}
