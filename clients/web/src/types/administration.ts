import type { Tenant, UserRole } from "./identity";
import type { Attachment } from "./messaging";

export interface AccountSession {
  id: string;
  user_id: string;
  device_id: string;
  expires_at: string;
  last_used_at: string;
  revoked_at?: string | null;
  inserted_at: string;
}

export interface TenantSettings {
  tenant_id: string;
  allow_audio_calls: boolean;
  allow_video_calls: boolean;
  allow_public_channels: boolean;
  message_edit_window_seconds: number;
  max_attachment_bytes: number;
  default_retention_days: number;
  max_active_users: number;
  max_active_conversations: number;
  max_conversation_members: number;
  version: number;
}

export interface TenantQuotaUsage {
  active_users: number;
  active_conversations: number;
  largest_conversation_members: number;
  limits: {
    max_active_users: number;
    max_active_conversations: number;
    max_conversation_members: number;
  };
  at_capacity: {
    active_users: boolean;
    active_conversations: boolean;
    conversation_members: boolean;
    any: boolean;
  };
  over_limit: {
    active_users: boolean;
    active_conversations: boolean;
    conversation_members: boolean;
    any: boolean;
  };
}

export interface TenantAdministration {
  tenant: Tenant;
  settings: TenantSettings;
  usage: TenantQuotaUsage;
}

export interface Invitation {
  id: string;
  email: string;
  role: Exclude<UserRole, "owner">;
  status: "pending" | "accepted" | "revoked" | "expired";
  invited_by_user_id: string;
  accepted_user_id?: string | null;
  expires_at: string;
  accepted_at?: string | null;
  revoked_at?: string | null;
  version: number;
  inserted_at: string;
}

export interface AuditEvent {
  id: string;
  actor_user_id?: string | null;
  action: string;
  resource_type: string;
  resource_id: string;
  metadata: Record<string, unknown>;
  request_id?: string | null;
  inserted_at: string;
}

export interface ModerationCase {
  id: string;
  reporter_user_id: string;
  subject_user_id?: string | null;
  conversation_id?: string | null;
  message_id?: string | null;
  assigned_to_user_id?: string | null;
  category: string;
  summary: string;
  details?: string | null;
  priority: "low" | "normal" | "high" | "urgent";
  status: "open" | "in_review" | "resolved" | "dismissed";
  resolved_at?: string | null;
  version: number;
  inserted_at: string;
  updated_at: string;
}

export interface RetentionPolicy {
  id: string;
  conversation_id?: string | null;
  name: string;
  scope_type: "tenant" | "conversation";
  retention_days: number;
  delete_attachments: boolean;
  status: "active" | "disabled";
  version: number;
  inserted_at: string;
  updated_at: string;
}

export interface LegalHold {
  id: string;
  created_by_user_id: string;
  subject_user_id?: string | null;
  conversation_id?: string | null;
  name: string;
  reason: string;
  scope_type: "tenant" | "user" | "conversation";
  status: "active" | "released";
  starts_at: string;
  released_at?: string | null;
  version: number;
  inserted_at: string;
}

export interface DeletionRequest {
  id: string;
  requested_by_user_id: string;
  subject_user_id?: string | null;
  conversation_id?: string | null;
  message_id?: string | null;
  target_type: "user" | "conversation" | "message";
  reason: string;
  status: "pending" | "approved" | "in_progress" | "completed" | "rejected" | "cancelled";
  scheduled_for?: string | null;
  completed_at?: string | null;
  evidence: Record<string, unknown>;
  version: number;
  inserted_at: string;
  updated_at: string;
}

export interface NotificationPreference {
  email_enabled: boolean;
  push_enabled: boolean;
  in_app_enabled: boolean;
  muted_event_types: string[];
  updated_at: string;
}

export interface PushSubscriptionConfig {
  available: boolean;
  vapid_public_key?: string | null;
}

export interface PushSubscriptionRecord {
  id: string;
  device_id: string;
  endpoint_hint: string;
  status: "active" | "revoked" | "expired" | "stale";
  expires_at?: string | null;
  revoked_at?: string | null;
  stale_at?: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface PushSubscriptionInput {
  endpoint: string;
  expiration_time: number | null;
  keys: { p256dh: string; auth: string };
}

export interface NotificationIntent {
  id: string;
  event_type: string;
  channel: string;
  destination_hint?: string | null;
  payload: Record<string, unknown>;
  status: string;
  attempt_count: number;
  delivered_at?: string | null;
  last_error_code?: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface InAppNotification {
  id: string;
  event_type: string;
  title: string;
  body: string;
  conversation_id?: string | null;
  message_id?: string | null;
  action_url?: string | null;
  read_at?: string | null;
  inserted_at: string;
}

export interface InAppNotificationPage {
  data: InAppNotification[];
  meta: { unread_count: number };
}

export interface NotificationAttempt {
  id: string;
  intent_id: string;
  attempt_number: number;
  provider: string;
  status: string;
  http_status?: number | null;
  error_code?: string | null;
  provider_message_id?: string | null;
  started_at: string;
  completed_at?: string | null;
}

export interface WebhookEndpoint {
  id: string;
  name: string;
  url: string;
  status: string;
  secret_version: number;
  event_types: string[];
  disabled_at?: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface WebhookDelivery {
  id: string;
  endpoint_id: string;
  event_type: string;
  status: string;
  attempt_count: number;
  next_attempt_at?: string | null;
  last_attempt_at?: string | null;
  delivered_at?: string | null;
  response_status?: number | null;
  last_error_code?: string | null;
  inserted_at: string;
  updated_at: string;
}

export type ServiceAccountScope =
  | "conversations:read"
  | "messages:read"
  | "messages:write"
  | "search:read";

export interface ServiceAccount {
  id: string;
  tenant_id: string;
  user_id: string;
  device_id: string;
  name: string;
  credential_prefix: string;
  secret_hint: string;
  scopes: ServiceAccountScope[];
  status: "active" | "revoked" | "expired";
  expires_at: string;
  last_used_at?: string | null;
  last_rotated_at: string;
  revoked_at?: string | null;
  version: number;
  inserted_at: string;
  updated_at: string;
}

export interface AttachmentSafety extends Attachment {
  owner_user_id: string;
  attempts: Array<{
    id: string;
    attempt_number: number;
    provider: string;
    status: string;
    verdict?: string | null;
    error_code?: string | null;
    provider_reference?: string | null;
    started_at: string;
    completed_at?: string | null;
  }>;
  inserted_at: string;
  updated_at: string;
}

export interface OperationsSnapshot {
  generated_at: string;
  release_revision: string;
  database?: { status: string };
  queues: Array<{ queue: string; state: string; count: number; oldest_scheduled_at?: string | null }>;
  outbox: { pending: number; published: number };
  notifications: Record<string, number>;
  webhooks: Record<string, number>;
  attachments: Record<string, number>;
  providers: Record<string, { status?: string; reason?: string; adapter?: string; test_only?: boolean; missing?: string[] } | string>;
}
