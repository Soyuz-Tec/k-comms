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
  account_type?: "human" | "service" | "guest";
  role: UserRole;
  platform_role?: PlatformRole | null;
  platform_role_expires_at?: string | null;
  status: string;
  version?: number;
}

export interface DirectoryPerson {
  id: string;
  display_name: string;
}

export interface RetainedSenderLabel {
  id: string;
  display_name: string;
  redacted: boolean;
}

export interface DirectoryPeoplePage {
  data: DirectoryPerson[];
  page: {
    next_cursor: string | null;
  };
}

export interface DirectConversationResponse {
  data: Conversation;
  created: boolean;
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

export interface GuestLink {
  id: string;
  conversation_id: string;
  expires_at: string;
  max_uses: number;
  use_count: number;
  conversion_enabled?: boolean;
  email_hint?: string | null;
  status: "active" | "expired" | "revoked" | "exhausted";
  revoked_at?: string | null;
  version?: number;
  share_url?: string;
}

export interface GuestCapabilities {
  allow_audio_calls: boolean;
  allow_video_calls: boolean;
  /**
   * Missing during a rolling upgrade is treated as disabled by the client.
   * Account conversion is available only on a host-preauthorized, single-use
   * link and still requires the separately delivered one-time code.
   */
  conversion_enabled?: boolean;
  /**
   * Instant-room guests can upgrade the identity already in the room without
   * a host-issued verifier. This is intentionally separate from the stricter
   * pre-authorized conversion used by ordinary guest invitations.
   */
  self_service_conversion?: boolean;
  /** Masked display hint only; the guest must enter the full authorized email. */
  email_hint?: string | null;
}

export interface GuestLinkPreview {
  room_title: string;
  expires_at: string;
  conversion_enabled: boolean;
  email_hint: string | null;
}

export interface GuestSession extends Session {
  conversation: Conversation;
  capabilities: GuestCapabilities;
  admission?: {
    guest_link_id: string;
    expires_at: string;
  };
  instant_room?: InstantRoom;
  /** The exact public URL returned by the server. Never reconstructed client-side. */
  share_url?: string;
}

export type InstantRoomOwnerKind = "guest" | "registered";
export type InstantRoomStatus = "active" | "idle" | "expired" | "revoked";

export interface InstantRoom {
  id: string;
  conversation_id: string;
  owner_user_id: string;
  status: InstantRoomStatus;
  owner_kind: InstantRoomOwnerKind;
  participant_limit: number;
  idle_since: string | null;
  expires_at: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface InstantRoomPreview {
  room_title: string;
  status: InstantRoomStatus;
  expires_at: string | null;
  participant_limit: number;
}

export interface InstantRoomResult {
  room: InstantRoom;
  conversation: Conversation;
  /** The exact public URL returned by the server. */
  share_url?: string;
  /** Present only when an anonymous visitor was admitted as the room creator. */
  guest_session?: GuestSession;
}

export interface SocketHandoff {
  ticket: string;
  expires_in: number;
}

export interface GuestAccountConversionResult {
  session: Session;
  conversation: Conversation;
  socket_handoff?: SocketHandoff;
}

export interface Conversation {
  id: string;
  tenant_id: string;
  kind: "direct" | "group" | "channel";
  title: string | null;
  counterpart_user_id: string | null;
  counterpart_display_name: string | null;
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

export type FileSafetyState =
  | "available"
  | "processing"
  | "blocked"
  | "failed"
  | "unavailable";

export type FilesScope = "recent" | "shared_by_me";

export interface FileSummary {
  id: string;
  conversation_id: string;
  message_id: string;
  conversation_sequence: number;
  owner_user_id: string;
  file_name: string;
  content_type: string;
  byte_size: number;
  status: Exclude<Attachment["status"], "deleted">;
  scan_status: NonNullable<Attachment["scan_status"]>;
  safety_state: FileSafetyState;
  downloadable: boolean;
  uploaded_at: string | null;
  shared_at: string;
  inserted_at: string;
  updated_at: string;
}

export interface FilesPageResponse {
  data: FileSummary[];
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}

export interface FilesQueryOptions {
  scope?: FilesScope;
  conversation_id?: string;
  limit?: number;
  cursor?: string | null;
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
  included?: {
    sender_labels: RetainedSenderLabel[];
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
  allow_audio_calls: boolean;
  allow_video_calls: boolean;
  allow_public_channels: boolean;
  message_edit_window_seconds: number;
  max_attachment_bytes: number;
}

export type CallMediaKind = "audio" | "video";

export interface Call {
  id: string;
  conversation_id: string;
  started_by_user_id: string;
  /** Omitted only by legacy audio broadcasts during a rolling deployment. */
  media_kind?: CallMediaKind;
  status: "active" | "ended";
  started_at: string;
  expires_at: string;
  ended_at?: string | null;
  can_end: boolean;
}

export interface CallRealtimeEvent {
  id: string;
  conversation_id: string;
  started_by_user_id: string;
  /** Omitted only by legacy audio broadcasts during a rolling deployment. */
  media_kind?: CallMediaKind;
  status: "active" | "ended";
  started_at: string;
  expires_at: string;
  ended_by_user_id?: string | null;
  ended_at?: string | null;
  end_reason?: string | null;
}

export interface CallCredential {
  server_url: string;
  participant_token: string;
  expires_in: number;
}

export interface CallSessionResponse {
  data: Call;
  credential: CallCredential;
}

export type CallsScope = "active" | "recent";

export interface CallSummary {
  id: string;
  conversation_id: string;
  started_by_user_id: string;
  ended_by_user_id: string | null;
  media_kind: CallMediaKind;
  status: "active" | "ending" | "ended";
  started_at: string;
  expires_at: string;
  ended_at: string | null;
  end_reason: string | null;
  duration_seconds: number;
  can_end: boolean;
}

export interface CallsPageResponse {
  data: CallSummary[];
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}

export interface CallsQueryOptions {
  scope?: CallsScope;
  media_kind?: CallMediaKind;
  limit?: number;
  cursor?: string | null;
}

/** Compatibility aliases for consumers migrating from the audio-only surface. */
export type AudioCall = Call;
export type AudioCallRealtimeEvent = CallRealtimeEvent;
export type AudioCallCredential = CallCredential;
export type AudioCallSessionResponse = CallSessionResponse;

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
  expires_at?: string;
  approved_origin?: string;
}

export interface MessagePage {
  data: Message[];
  included?: {
    sender_labels: RetainedSenderLabel[];
  };
  page: {
    has_more: boolean;
    next_after_sequence: number | null;
    reset_required: boolean;
  };
}

export interface MessageSearchOptions {
  conversation_id?: string;
  sender_user_id?: string;
  after?: string;
  before?: string;
  cursor?: string | null;
  limit?: number;
}

export interface MessageSearchPage {
  data: Message[];
  included?: {
    sender_labels: RetainedSenderLabel[];
  };
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}

export interface ServiceStatus {
  service: string;
  version: string;
  status: string;
  node?: string;
  capabilities?: {
    administration: boolean;
    audio_calls?: boolean;
    video_calls?: boolean;
    attachment_scanning: boolean;
    bootstrap: boolean;
    guest_links: boolean;
    instant_rooms: boolean;
    notifications: boolean;
    push_notifications?: boolean;
    realtime: boolean;
    secure_account_actions: boolean;
    secure_media_actions: boolean;
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
