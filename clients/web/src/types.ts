export interface Tenant {
  id: string;
  name: string;
  slug: string;
  status: string;
}

export type UserRole =
  | "member"
  | "moderator"
  | "admin"
  | "compliance_admin"
  | "security_admin"
  | "owner";

export type PlatformRole = "platform_operator" | "support_operator" | "security_operator";

export interface User {
  id: string;
  tenant_id: string;
  display_name: string;
  email?: string | null;
  account_type?: "human" | "service";
  role: UserRole;
  platform_role?: PlatformRole | null;
  platform_role_expires_at?: string | null;
  status: string;
  version?: number;
}

export interface Device {
  id: string;
  user_id: string;
  name: string;
  platform: string;
  last_seen_at?: string | null;
  revoked_at?: string | null;
}

export interface Session {
  access_token: string;
  refresh_token: string;
  token_type: string;
  expires_in: number;
  received_at?: number;
  tenant: Tenant;
  user: User;
  device: Device;
}

export interface Conversation {
  id: string;
  tenant_id: string;
  kind: "direct" | "group" | "channel";
  title: string | null;
  visibility: "private" | "tenant";
  latest_sequence: number;
  membership_role?: string;
  last_read_sequence?: number;
  unread_count?: number;
  archived_at?: string | null;
  version?: number;
  inserted_at: string;
  updated_at: string;
}

export interface ConversationMembership {
  id: string;
  role: "member" | "moderator" | "owner";
  joined_at: string;
  last_read_sequence: number;
  version?: number;
  user: User;
}

export interface MembershipSummary {
  id: string;
  role: "member" | "moderator" | "owner";
  joined_at: string;
  left_at: string | null;
  last_read_sequence: number;
  version: number;
}

export interface PublicChannel extends Conversation {
  joined: boolean;
  member_count: number;
  membership: MembershipSummary | null;
}

export interface PublicChannelDiscoveryPage {
  data: PublicChannel[];
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}

export interface PublicChannelMembershipResponse {
  data: {
    conversation: Conversation;
    membership: MembershipSummary;
  };
  replayed: boolean;
}

export interface Reaction {
  id?: string;
  user_id: string;
  emoji: string;
}

export interface Attachment {
  id: string;
  message_id?: string | null;
  file_name: string;
  content_type: string;
  byte_size: number;
  checksum_sha256?: string | null;
  status: "pending" | "uploaded" | "ready" | "quarantined" | "scan_failed" | "deleted";
  scan_status?: "pending" | "scanning" | "clean" | "blocked" | "failed" | null;
  scan_verdict?: string | null;
  scan_provider?: string | null;
  scan_attempts?: number;
  scan_error_code?: string | null;
  scanned_at?: string | null;
  quarantined_at?: string | null;
  uploaded_at?: string | null;
}

export interface Message {
  id: string;
  tenant_id: string;
  conversation_id: string;
  sender_user_id: string;
  sender_device_id: string;
  reply_to_message_id?: string | null;
  thread_root_message_id?: string | null;
  thread_reply_count?: number;
  mentioned_user_ids?: string[];
  client_message_id: string;
  conversation_sequence: number;
  body: string | null;
  metadata: Record<string, unknown>;
  status: "active" | "deleted" | "moderated";
  edited_at?: string | null;
  deleted_at?: string | null;
  inserted_at: string;
  attachments: Attachment[];
  reactions: Reaction[];
}

export interface MessageThread {
  data: {
    root: Message;
    replies: Message[];
    reply_count: number;
  };
  page: {
    has_more: boolean;
    next_before_sequence: number | null;
  };
}

export interface MeResponse {
  tenant: Tenant;
  user: User;
  device: Device;
  capabilities: UserCapabilities;
}

export interface UserCapabilities {
  allow_public_channels: boolean;
  message_edit_window_seconds: number;
  max_attachment_bytes: number;
}

export interface ListResponse<T> {
  data: T[];
}

export interface DataResponse<T> {
  data: T;
}

export interface UploadDescriptor {
  url?: string;
  upload_url?: string;
  href?: string;
  method?: string;
  headers?: Record<string, string>;
  fields?: Record<string, string>;
  expires_in?: number;
  approved_origin?: string;
}

export interface MessagePage {
  data: Message[];
  page: {
    has_more: boolean;
    next_after_sequence: number | null;
    reset_required: boolean;
  };
}

export interface ServiceStatus {
  service: string;
  version: string;
  status: string;
  node?: string;
  capabilities?: {
    administration: boolean;
    attachment_scanning: boolean;
    bootstrap: boolean;
    notifications: boolean;
    realtime: boolean;
    webhooks: boolean;
  };
}

export interface HealthStatus {
  status: "ok" | "ready" | "not_ready" | string;
}

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
  database?: { status: string };
  queues: Array<{ queue: string; state: string; count: number; oldest_scheduled_at?: string | null }>;
  outbox: { pending: number; published: number };
  notifications: Record<string, number>;
  webhooks: Record<string, number>;
  attachments: Record<string, number>;
  providers: Record<string, { status?: string; reason?: string; adapter?: string } | string>;
}

export interface MembershipEvent {
  user_id: string;
  action: "added" | "removed" | "role_changed";
  role?: ConversationMembership["role"];
}

export interface ConversationActivityEvent {
  conversation_id: string;
  latest_sequence: number;
  event_type: string;
}

export interface ConversationMembershipEvent {
  conversation_id: string;
  action: "added" | "removed";
}

export interface NotificationAvailableEvent {
  notification_id: string;
  event_type: string;
  conversation_id?: string | null;
  message_id?: string | null;
  unread_count: number;
}

export interface AttachmentIntentResponse extends DataResponse<Attachment> {
  upload: UploadDescriptor;
}

export interface AttachmentDownloadResponse extends DataResponse<Attachment> {
  download?: UploadDescriptor;
}

export interface ReadCursorEvent {
  user_id: string;
  sequence: number;
}

export interface ReactionEvent {
  message_id: string;
  emoji: string;
  user_id: string;
}

export type ConnectionStatus = "connecting" | "live" | "reconnecting" | "offline";
