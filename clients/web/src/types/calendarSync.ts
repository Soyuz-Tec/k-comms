export type CalendarProvider = "google" | "microsoft";
export interface CalendarConnection {
  id: string; provider: CalendarProvider; version: number; consent_generation: number;
  status: "awaiting_consent" | "ready" | "reauthorization_required" | "removing" | "held_cleanup_blocked" | "removed";
  new_exports_allowed: boolean; permission_status: "unverified" | "scopes_verified" | "verified";
  provider_grant_revocation: "not_requested" | "pending" | "confirmed" | "external_unconfirmed" | "failed";
  managed_events_pending_removal: number; last_success_at: string | null; safe_reason: string | null;
}
export interface CalendarConnectionsResponse {
  data: CalendarConnection[];
  meta: { mode: "one_way_hosted_occurrences"; policy: { export_allowed: boolean; version: number };
    providers: { provider: CalendarProvider; configured: boolean; qualified: boolean; safe_reason: string | null }[] };
}
export interface CalendarExport {
  id: string; connection_id: string; meeting_id: string; version: number;
  status: "pending" | "synced" | "conflict" | "stopping" | "removed" | "blocked" | "failed" | "uncertain";
  desired_meeting_version: number; applied_meeting_version: number | null; occurrence_count: number; safe_reason: string | null;
}
