import type { UsageProjection, UsageReport } from "../../types/usage";

function projection(current: Record<string, number>, metrics: Record<string, number>): UsageProjection {
  return { observed_at: "2000-01-03T12:00:00Z", earliest_retained_at: "2000-01-01T00:00:00Z", current,
    daily: [{ date: "2000-01-01", metrics }, { date: "2000-01-02", metrics: Object.fromEntries(Object.keys(metrics).map((key) => [key, 0])) }] };
}
export function usageFixture(overrides: Partial<UsageReport> = {}): UsageReport {
  return {
    range: { from: "2000-01-01", through: "2000-01-02", time_zone: "UTC" }, observed_at: "2000-01-03T12:00:00Z",
    coverage: "currently_retained_records", lifetime_complete: false,
    sources: {
      identity: { status: "available", data: projection({ active_humans: 2, active_services: 0 }, { humans_created: 2, services_created: 0 }) },
      conversations: { status: "available", data: projection({ active_conversations: 0 }, { direct_created: 0, group_created: 0, channel_created: 0 }) },
      messages: { status: "available", data: projection({ retained_messages: 7 }, { created: 7, current_active: 3, current_deleted: 4, current_moderated: 0 }) },
      attachments: { status: "unavailable", data: null },
      calls: { status: "available", data: projection({ current_active: 0, current_ending: 0 }, { started: 0, audio_started: 0, video_started: 0, status_active: 0, status_ending: 0, status_ended: 0, observed_room_seconds: 120 }) },
      telephony: { status: "unavailable", data: null }
    }, ...overrides
  };
}
