export type UsageSourceKey = "identity" | "conversations" | "messages" | "attachments" | "calls" | "telephony";
type IdentityMetric = "active_humans" | "active_services" | "humans_created" | "services_created";
type ConversationMetric = "active_conversations" | "direct_created" | "group_created" | "channel_created";
type MessageMetric = "retained_messages" | "created" | "current_active" | "current_deleted" | "current_moderated";
type AttachmentMetric = "ready_retained_count" | "ready_retained_bytes" | "created" | "ready_count" | "ready_bytes";
type CallMetric = "current_active" | "current_ending" | "started" | "audio_started" | "video_started" | "status_active" | "status_ending" | "status_ended" | "observed_room_seconds";
type TelephonyMetric = "current_ringing" | "current_answered" | "started" | "inbound_started" | "outbound_started" | "status_ringing" | "status_answered" | "status_declined" | "status_no_answer" | "status_cancelled" | "status_failed" | "status_ended" | "status_busy" | "observed_answered_seconds";

export interface UsageQuery { from?: string; through?: string }
export interface UsageProjection<Metric extends string = string> {
  observed_at: string;
  earliest_retained_at: string | null;
  current: Partial<Record<Metric, number>>;
  daily: Array<{ date: string; metrics: Partial<Record<Metric, number>> }>;
}
export type UsageSource<Metric extends string = string> =
  | { status: "available"; data: UsageProjection<Metric> }
  | { status: "unavailable"; data: null };
export interface UsageReport {
  range: { from: string; through: string; time_zone: "UTC" };
  observed_at: string;
  coverage: "currently_retained_records";
  lifetime_complete: false;
  sources: {
    identity: UsageSource<IdentityMetric>;
    conversations: UsageSource<ConversationMetric>;
    messages: UsageSource<MessageMetric>;
    attachments: UsageSource<AttachmentMetric>;
    calls: UsageSource<CallMetric>;
    telephony: UsageSource<TelephonyMetric>;
  };
}
export interface UsageExportReceipt {
  from: string;
  through: string;
  timeZone: "UTC";
  observedAt: string;
  unavailableSources: number;
}
export interface UsageExportFile { blob: Blob; filename: string; usage: UsageExportReceipt }
