import type { DeletionRequest } from "../../types";
import type { DeletionHistoryEvent, DeletionHistoryPage } from "../../types/deletionHistory";

export function historyEvent(overrides: Partial<DeletionHistoryEvent> = {}): DeletionHistoryEvent {
  return {
    id: "synthetic-created-event", inserted_at: "2026-10-05T00:00:00Z", action: "deletion_request.create",
    actor: { kind: "user", user_id: "synthetic-owner", display_name: "History Reviewer" },
    status: "pending", attempt: null, version: 1, error_code: null,
    proof_versions: {}, counts: {}, ...overrides
  };
}
export function historyRequest(overrides: Partial<DeletionRequest> = {}): DeletionRequest {
  return {
    id: "deletion-1", requested_by_user_id: "synthetic-owner", subject_user_id: "synthetic-target",
    target_type: "user", reason: "Synthetic authored erasure request", status: "approved", version: 2,
    execution_attempts: 2, execution_error: "verification_pending", evidence: { messages_tombstoned: 3, writer_fence_erasure_version: 1 },
    scheduled_for: "2026-10-05T00:00:00Z", inserted_at: "2026-10-05T00:00:00Z", updated_at: "2026-10-05T00:01:00Z", ...overrides
  };
}
export function historyPage(overrides: Partial<DeletionHistoryPage> = {}): DeletionHistoryPage {
  return {
    request: historyRequest(), events: [historyEvent()], limit: 25, next_cursor: null,
    snapshot: "synthetic-snapshot", observed_at: "2026-10-05T00:02:00Z", snapshot_observed_at: "2026-10-05T00:01:00Z",
    coverage: { state: "available", retained_only: true, version_lineage: "unproven", origin_present: true, earliest_at: "2026-10-05T00:00:00Z",
      snapshot_truncated: false, captured_count: 1, retained_count: 1, maximum_events: 5000 }, ...overrides
  };
}
