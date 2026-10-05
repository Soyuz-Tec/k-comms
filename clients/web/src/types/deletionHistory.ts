import type { DeletionRequest } from "./administration";

export type HistoryCoverageState = "available" | "partial" | "unavailable";
export type DeletionHistoryAction = "deletion_request.create" | "deletion_request.approved" | "deletion_request.rejected" | "deletion_request.cancelled" |
  "deletion_request.claim" | "deletion_request.failure" | "deletion_request.writer_fence_repair_queued" | "deletion_request.completed" | "deletion_request.derived_content_repaired";

export interface DeletionHistoryEvent {
  id: string;
  actor: { kind: "user" | "system" | "unavailable"; user_id: string | null; display_name: string | null };
  inserted_at: string;
  action: DeletionHistoryAction;
  status: DeletionRequest["status"] | null;
  attempt: number | null;
  error_code: "provider_failure" | "verification_pending" | "unavailable" | null;
  version: number | null;
  proof_versions: Record<string, number>;
  counts: Record<string, number>;
}

export interface DeletionHistoryPage {
  request: DeletionRequest;
  events: DeletionHistoryEvent[];
  limit: number;
  next_cursor: string | null;
  snapshot: string;
  observed_at: string;
  snapshot_observed_at: string;
  coverage: {
    state: HistoryCoverageState;
    retained_only: true;
    version_lineage: "unproven";
    origin_present: boolean;
    earliest_at: string | null;
    snapshot_truncated: boolean;
    captured_count: number;
    retained_count: number;
    maximum_events: number;
  };
}

export interface DeletionHistoryQuery {
  limit?: number;
  cursor?: string;
  snapshot?: string;
}

export interface DeletionHistoryExportReceipt {
  snapshot: string;
  coverage: HistoryCoverageState;
  retainedOnly: true;
  maximumRows: number;
  observedAt: string;
}

export interface DeletionHistoryExportFile {
  blob: Blob;
  filename: string;
  count: number;
  truncated: boolean;
  history: DeletionHistoryExportReceipt;
}
