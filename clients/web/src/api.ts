import type {
  AccountSession,
  Call,
  CallMediaKind,
  CallsPageResponse,
  CallsQueryOptions,
  CallSessionResponse,
  Attachment,
  AttachmentSafety,
  AttachmentDownloadResponse,
  AttachmentIntentResponse,
  Conversation,
  ConversationMembership,
  DeletionRequest,
  DataResponse,
  Device,
  DirectoryPeoplePage,
  DirectConversationResponse,
  HealthStatus,
  Invitation,
  InAppNotification,
  InAppNotificationPage,
  LegalHold,
  ListResponse,
  MeResponse,
  Message,
  MessagePage,
  MessageSearchOptions,
  MessageSearchPage,
  MessageThread,
  ModerationCase,
  NotificationAttempt,
  NotificationIntent,
  NotificationPreference,
  OperationsSnapshot,
  FilesPageResponse,
  FilesQueryOptions,
  GuestLink,
  GuestLinkPreview,
  GuestSession,
  PublicChannelDiscoveryPage,
  PublicChannelMembershipResponse,
  PushSubscriptionConfig,
  PushSubscriptionInput,
  PushSubscriptionRecord,
  AuditEvent,
  RetentionPolicy,
  Session,
  ServiceAccount,
  ServiceAccountScope,
  ServiceStatus,
  TenantAdministration,
  UploadDescriptor,
  UserRole,
  User,
  WebhookDelivery,
  WebhookEndpoint
} from "./types";

const sessionKey = "k-comms.session.v1";
const guestSessionKey = "k-comms.guest-session.v1";

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly meta?: unknown;

  constructor(status: number, code: string, message: string, meta?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.meta = meta;
  }
}

export function loadStoredSession(): Session | null {
  try {
    const value = window.sessionStorage.getItem(sessionKey);
    return value ? (JSON.parse(value) as Session) : null;
  } catch {
    window.sessionStorage.removeItem(sessionKey);
    return null;
  }
}

export function storeSession(session: Session | null): void {
  if (session) {
    window.sessionStorage.setItem(sessionKey, JSON.stringify(session));
  } else {
    window.sessionStorage.removeItem(sessionKey);
  }
}

export function loadStoredGuestSession(): GuestSession | null {
  try {
    const value = window.sessionStorage.getItem(guestSessionKey);
    if (!value) return null;
    const session = JSON.parse(value) as GuestSession;
    if (
      !session.access_token ||
      !session.refresh_token ||
      session.user?.account_type !== "guest" ||
      !session.conversation?.id
    ) {
      throw new Error("Invalid guest session");
    }
    return session;
  } catch {
    window.sessionStorage.removeItem(guestSessionKey);
    return null;
  }
}

export function storeGuestSession(session: GuestSession | null): void {
  if (session) {
    window.sessionStorage.setItem(guestSessionKey, JSON.stringify(session));
  } else {
    window.sessionStorage.removeItem(guestSessionKey);
  }
}

interface ErrorEnvelope {
  error?: {
    code?: string;
    detail?: string;
    meta?: unknown;
  };
}

interface RequestOptions extends RequestInit {
  retryAuthentication?: boolean;
}

export interface BootstrapInput {
  tenant_name: string;
  tenant_slug: string;
  display_name: string;
  email: string;
  password: string;
  device_name: string;
  device_platform: "web";
}

export interface LoginInput {
  tenant_slug: string;
  email: string;
  password: string;
  device: { name: string; platform: "web" };
}

export interface CreateConversationInput {
  title?: string;
  kind: "direct" | "group" | "channel";
  visibility: "private" | "tenant";
  member_ids: string[];
}

export interface SendMessageInput {
  client_message_id: string;
  body: string;
  attachment_ids: string[];
  reply_to_message_id?: string | null;
  mentioned_user_ids?: string[];
}

export interface UpdateTenantInput {
  name: string;
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

export interface CreateServiceAccountInput {
  name: string;
  scopes: ServiceAccountScope[];
  expires_at: string;
  reason: string;
}

export interface AuditExportInput {
  q?: string;
  action?: string;
  resource_type?: string;
  actor_user_id?: string;
  request_id?: string;
  after?: string;
  before?: string;
  limit?: number;
}

export interface AuditExportFile {
  blob: Blob;
  filename: string;
  count: number;
  truncated: boolean;
}

export class ApiClient {
  private session: Session | null;
  private refreshPromise: Promise<Session | null> | null = null;
  private refreshController: AbortController | null = null;
  private sessionGeneration = 0;

  constructor(
    private readonly baseUrl: string,
    initialSession: Session | null,
    private readonly onSession: (session: Session | null) => void
  ) {
    this.session = initialSession;
  }

  setSession(session: Session | null): void {
    if (
      this.session?.access_token !== session?.access_token ||
      this.session?.refresh_token !== session?.refresh_token
    ) {
      this.sessionGeneration += 1;
      if (!session) this.refreshController?.abort();
    }
    this.session = session;
  }

  bootstrap(input: BootstrapInput): Promise<Session & { conversation: Conversation }> {
    return this.request<Session & { conversation: Conversation }>("/api/v1/bootstrap", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then(withReceivedAt);
  }

  login(input: LoginInput): Promise<Session> {
    return this.request<Session>("/api/v1/sessions", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then(withReceivedAt);
  }

  requestPasswordRecovery(input: { tenant_slug: string; email: string }): Promise<void> {
    return this.request("/api/v1/password-recovery/requests", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    });
  }

  resetPassword(input: { token: string; new_password: string }): Promise<void> {
    return this.request("/api/v1/password-recovery/resets", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    });
  }

  acceptInvitation(input: { token: string; display_name: string; password: string }): Promise<User> {
    return this.request<DataResponse<User>>("/api/v1/invitations/accept", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then((response) => response.data);
  }

  me(): Promise<MeResponse> {
    return this.request("/api/v1/me");
  }

  updateProfile(input: { display_name: string }): Promise<User> {
    return this.request<DataResponse<User>>("/api/v1/me/profile", {
      method: "PATCH",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  changePassword(input: { current_password: string; new_password: string }): Promise<void> {
    return this.request("/api/v1/me/password", { method: "PUT", body: JSON.stringify(input) });
  }

  stepUp(currentPassword: string): Promise<{ step_up_at: string }> {
    return this.request<DataResponse<{ step_up_at: string }>>("/api/v1/me/step-up", {
      method: "POST",
      body: JSON.stringify({ current_password: currentPassword })
    }).then((response) => response.data);
  }

  socketTicket(): Promise<{ ticket: string; expires_in: number }> {
    return this.request<DataResponse<{ ticket: string; expires_in: number }>>("/api/v1/socket-tickets", {
      method: "POST"
    }).then((response) => response.data);
  }

  devices(): Promise<Device[]> {
    return this.request<ListResponse<Device>>("/api/v1/me/devices").then(
      (response) => response.data
    );
  }

  revokeDevice(id: string): Promise<void> {
    return this.request(`/api/v1/me/devices/${encodeURIComponent(id)}`, { method: "DELETE" });
  }

  sessions(): Promise<AccountSession[]> {
    return this.request<ListResponse<AccountSession>>("/api/v1/me/sessions").then(
      (response) => response.data
    );
  }

  revokeSession(id: string): Promise<void> {
    return this.request(`/api/v1/me/sessions/${encodeURIComponent(id)}`, { method: "DELETE" });
  }

  users(): Promise<User[]> {
    return this.request<ListResponse<User>>("/api/v1/users").then((response) => response.data);
  }

  directoryUsers(
    query = "",
    limit = 25,
    cursor?: string | null
  ): Promise<DirectoryPeoplePage> {
    const params = new URLSearchParams({ q: query, limit: String(limit) });
    if (cursor) params.set("cursor", cursor);
    return this.request(`/api/v1/directory/users?${params.toString()}`);
  }

  directConversation(userId: string): Promise<DirectConversationResponse> {
    return this.request("/api/v1/direct-conversations", {
      method: "POST",
      body: JSON.stringify({ user_id: userId })
    });
  }

  adminUsers(): Promise<User[]> {
    return this.request<ListResponse<User>>("/api/v1/admin/users").then((response) => response.data);
  }

  updateAdminUser(id: string, input: { role?: UserRole; status?: string; display_name?: string; reason?: string; version: number }): Promise<User> {
    return this.request<DataResponse<User>>(`/api/v1/admin/users/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  adminUserSessions(userId: string): Promise<AccountSession[]> {
    return this.request<ListResponse<AccountSession>>(`/api/v1/admin/users/${encodeURIComponent(userId)}/sessions`).then(
      (response) => response.data
    );
  }

  adminRevokeSession(userId: string, sessionId: string, reason?: string): Promise<void> {
    return this.request(`/api/v1/admin/users/${encodeURIComponent(userId)}/sessions/${encodeURIComponent(sessionId)}`, {
      method: "DELETE",
      body: reason ? JSON.stringify({ reason }) : undefined
    });
  }

  tenantAdministration(): Promise<TenantAdministration> {
    return this.request<DataResponse<TenantAdministration>>("/api/v1/admin/tenant").then(
      (response) => response.data
    );
  }

  updateTenantAdministration(input: UpdateTenantInput): Promise<TenantAdministration> {
    return this.request<DataResponse<TenantAdministration>>("/api/v1/admin/tenant", {
      method: "PATCH",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  invitations(): Promise<Invitation[]> {
    return this.request<ListResponse<Invitation>>("/api/v1/admin/invitations").then(
      (response) => response.data
    );
  }

  createInvitation(input: { email: string; role: Exclude<UserRole, "owner"> }): Promise<{ invitation: Invitation; invitationToken?: string | null }> {
    return this.request<{ data: Invitation; invitation_token?: string | null }>("/api/v1/admin/invitations", {
      method: "POST",
      headers: { "Idempotency-Key": operationId() },
      body: JSON.stringify(input)
    }).then((response) => ({ invitation: response.data, invitationToken: response.invitation_token }));
  }

  revokeInvitation(id: string, version: number, reason?: string): Promise<Invitation> {
    return this.request<DataResponse<Invitation>>(`/api/v1/admin/invitations/${encodeURIComponent(id)}/revoke`, {
      method: "POST",
      body: JSON.stringify({ version, reason })
    }).then((response) => response.data);
  }

  auditEvents(limit = 100): Promise<AuditEvent[]> {
    return this.request<ListResponse<AuditEvent>>(`/api/v1/admin/audit-events?limit=${limit}`).then(
      (response) => response.data
    );
  }

  exportAuditEvents(input: AuditExportInput = {}): Promise<AuditExportFile> {
    return this.download("/api/v1/admin/audit-events/export", {
      method: "POST",
      body: JSON.stringify(input)
    });
  }

  moderationCases(): Promise<ModerationCase[]> {
    return this.request<ListResponse<ModerationCase>>("/api/v1/moderation/cases").then(
      (response) => response.data
    );
  }

  createModerationCase(input: { subject_user_id?: string; conversation_id?: string; message_id?: string; category: string; summary: string; details?: string; priority?: string }): Promise<ModerationCase> {
    return this.request<DataResponse<ModerationCase>>("/api/v1/moderation/cases", {
      method: "POST",
      headers: { "Idempotency-Key": operationId() },
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  addModerationAction(id: string, input: { action_type: string; note: string; version: number }): Promise<ModerationCase> {
    return this.request<{ data: ModerationCase }>(`/api/v1/moderation/cases/${encodeURIComponent(id)}/actions`, {
      method: "POST",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  retentionPolicies(): Promise<RetentionPolicy[]> {
    return this.request<ListResponse<RetentionPolicy>>("/api/v1/admin/retention-policies").then(
      (response) => response.data
    );
  }

  createRetentionPolicy(input: { name: string; retention_days: number; delete_attachments: boolean }): Promise<RetentionPolicy> {
    return this.request<DataResponse<RetentionPolicy>>("/api/v1/admin/retention-policies", {
      method: "POST",
      headers: { "Idempotency-Key": operationId() },
      body: JSON.stringify({ ...input, scope_type: "tenant", status: "active" })
    }).then((response) => response.data);
  }

  updateRetentionPolicy(id: string, input: { status: "active" | "disabled"; version: number; reason: string }): Promise<RetentionPolicy> {
    return this.request<DataResponse<RetentionPolicy>>(`/api/v1/admin/retention-policies/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  legalHolds(): Promise<LegalHold[]> {
    return this.request<ListResponse<LegalHold>>("/api/v1/admin/legal-holds").then(
      (response) => response.data
    );
  }

  createLegalHold(input: {
    name: string;
    reason: string;
    scope_type: "tenant" | "user" | "conversation";
    target_id?: string;
  }): Promise<LegalHold> {
    const { target_id: targetId, ...body } = input;
    const targetField = input.scope_type === "user"
      ? "subject_user_id"
      : input.scope_type === "conversation"
        ? "conversation_id"
        : null;
    return this.request<DataResponse<LegalHold>>("/api/v1/admin/legal-holds", {
      method: "POST",
      headers: { "Idempotency-Key": operationId() },
      body: JSON.stringify({ ...body, ...(targetField && targetId ? { [targetField]: targetId } : {}) })
    }).then((response) => response.data);
  }

  releaseLegalHold(id: string, version: number, releaseReason: string): Promise<LegalHold> {
    return this.request<DataResponse<LegalHold>>(`/api/v1/admin/legal-holds/${encodeURIComponent(id)}/release`, {
      method: "POST",
      body: JSON.stringify({ version, release_reason: releaseReason })
    }).then((response) => response.data);
  }

  deletionRequests(): Promise<DeletionRequest[]> {
    return this.request<ListResponse<DeletionRequest>>("/api/v1/admin/deletion-requests").then(
      (response) => response.data
    );
  }

  createDeletionRequest(input: { target_type: "user" | "conversation" | "message"; target_id: string; reason: string }): Promise<DeletionRequest> {
    const targetField = input.target_type === "user" ? "subject_user_id" : `${input.target_type}_id`;
    return this.request<DataResponse<DeletionRequest>>("/api/v1/admin/deletion-requests", {
      method: "POST",
      headers: { "Idempotency-Key": operationId() },
      body: JSON.stringify({ target_type: input.target_type, [targetField]: input.target_id, reason: input.reason })
    }).then((response) => response.data);
  }

  updateDeletionRequest(id: string, input: { status: string; version: number; transition_reason: string }): Promise<DeletionRequest> {
    return this.request<DataResponse<DeletionRequest>>(`/api/v1/admin/deletion-requests/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  notificationPreference(): Promise<NotificationPreference> {
    return this.request<DataResponse<NotificationPreference>>("/api/v1/notification-preferences").then(
      (response) => response.data
    );
  }

  updateNotificationPreference(input: Pick<NotificationPreference, "email_enabled" | "push_enabled" | "in_app_enabled" | "muted_event_types">): Promise<NotificationPreference> {
    return this.request<DataResponse<NotificationPreference>>("/api/v1/notification-preferences", {
      method: "PUT",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  notifications(): Promise<NotificationIntent[]> {
    return this.request<ListResponse<NotificationIntent>>("/api/v1/notifications").then(
      (response) => response.data
    );
  }

  notificationAttempts(): Promise<NotificationAttempt[]> {
    return this.request<ListResponse<NotificationAttempt>>("/api/v1/notification-attempts").then(
      (response) => response.data
    );
  }

  retryNotification(id: string): Promise<NotificationIntent> {
    return this.request<DataResponse<NotificationIntent>>(`/api/v1/notification-intents/${encodeURIComponent(id)}/retry`, { method: "POST" }).then(
      (response) => response.data
    );
  }

  pushSubscriptionConfig(): Promise<PushSubscriptionConfig> {
    return this.request<DataResponse<PushSubscriptionConfig>>(
      "/api/v1/me/push-subscriptions/config"
    ).then((response) => response.data);
  }

  pushSubscriptions(): Promise<PushSubscriptionRecord[]> {
    return this.request<ListResponse<PushSubscriptionRecord>>(
      "/api/v1/me/push-subscriptions"
    ).then((response) => response.data);
  }

  registerPushSubscription(input: PushSubscriptionInput): Promise<{ data: PushSubscriptionRecord; replayed: boolean }> {
    return this.request("/api/v1/me/push-subscriptions", {
      method: "POST",
      body: JSON.stringify(input)
    });
  }

  revokePushSubscription(id: string): Promise<PushSubscriptionRecord> {
    return this.request<DataResponse<PushSubscriptionRecord>>(
      `/api/v1/me/push-subscriptions/${encodeURIComponent(id)}`,
      { method: "DELETE" }
    ).then((response) => response.data);
  }

  inAppNotifications(limit = 50): Promise<InAppNotificationPage> {
    return this.request(`/api/v1/in-app-notifications?limit=${Math.max(1, Math.min(limit, 100))}`);
  }

  inAppUnreadCount(): Promise<number> {
    return this.request<DataResponse<{ unread_count: number }>>(
      "/api/v1/in-app-notifications/unread-count"
    ).then((response) => response.data.unread_count);
  }

  markInAppNotificationRead(id: string): Promise<InAppNotification> {
    return this.request<DataResponse<InAppNotification>>(
      `/api/v1/in-app-notifications/${encodeURIComponent(id)}/read`,
      { method: "PATCH" }
    ).then((response) => response.data);
  }

  dismissInAppNotification(id: string): Promise<InAppNotification> {
    return this.request<DataResponse<InAppNotification>>(
      `/api/v1/in-app-notifications/${encodeURIComponent(id)}`,
      { method: "DELETE" }
    ).then((response) => response.data);
  }

  markAllInAppNotificationsRead(): Promise<{ updated_count: number; unread_count: number }> {
    return this.request<DataResponse<{ updated_count: number; unread_count: number }>>(
      "/api/v1/in-app-notifications/read-all",
      { method: "POST" }
    ).then((response) => response.data);
  }

  webhooks(): Promise<WebhookEndpoint[]> {
    return this.request<ListResponse<WebhookEndpoint>>("/api/v1/admin/webhooks").then(
      (response) => response.data
    );
  }

  createWebhook(input: { name: string; url: string; event_types: string[] }): Promise<{ endpoint: WebhookEndpoint; secret: string }> {
    return this.request<{ data: WebhookEndpoint; secret: string }>("/api/v1/admin/webhooks", {
      method: "POST",
      body: JSON.stringify(input)
    }).then((response) => ({ endpoint: response.data, secret: response.secret }));
  }

  rotateWebhookSecret(id: string, reason?: string): Promise<{ endpoint: WebhookEndpoint; secret: string }> {
    return this.request<{ data: WebhookEndpoint; secret: string }>(`/api/v1/admin/webhooks/${encodeURIComponent(id)}/rotate-secret`, {
      method: "POST",
      body: reason ? JSON.stringify({ reason }) : undefined
    }).then(
      (response) => ({ endpoint: response.data, secret: response.secret })
    );
  }

  disableWebhook(id: string, reason?: string): Promise<void> {
    return this.request(`/api/v1/admin/webhooks/${encodeURIComponent(id)}`, {
      method: "DELETE",
      body: reason ? JSON.stringify({ reason }) : undefined
    });
  }

  webhookDeliveries(): Promise<WebhookDelivery[]> {
    return this.request<ListResponse<WebhookDelivery>>("/api/v1/admin/webhook-deliveries").then(
      (response) => response.data
    );
  }

  serviceAccounts(): Promise<ServiceAccount[]> {
    return this.request<ListResponse<ServiceAccount>>("/api/v1/admin/service-accounts").then(
      (response) => response.data
    );
  }

  createServiceAccount(input: CreateServiceAccountInput): Promise<{ account: ServiceAccount; credential: string }> {
    return this.request<{ data: ServiceAccount; credential: string }>("/api/v1/admin/service-accounts", {
      method: "POST",
      body: JSON.stringify(input)
    }).then((response) => ({ account: response.data, credential: response.credential }));
  }

  rotateServiceAccount(id: string, version: number, reason: string): Promise<{ account: ServiceAccount; credential: string }> {
    return this.request<{ data: ServiceAccount; credential: string }>(`/api/v1/admin/service-accounts/${encodeURIComponent(id)}/rotate`, {
      method: "POST",
      body: JSON.stringify({ version, reason })
    }).then((response) => ({ account: response.data, credential: response.credential }));
  }

  revokeServiceAccount(id: string, version: number, reason: string): Promise<ServiceAccount> {
    return this.request<DataResponse<ServiceAccount>>(`/api/v1/admin/service-accounts/${encodeURIComponent(id)}/revoke`, {
      method: "POST",
      body: JSON.stringify({ version, reason })
    }).then((response) => response.data);
  }

  replayWebhookDelivery(id: string): Promise<WebhookDelivery> {
    return this.request<DataResponse<WebhookDelivery>>(`/api/v1/admin/webhook-deliveries/${encodeURIComponent(id)}/replay`, { method: "POST" }).then(
      (response) => response.data
    );
  }

  attachmentSafety(): Promise<AttachmentSafety[]> {
    return this.request<ListResponse<AttachmentSafety>>("/api/v1/admin/attachment-safety").then(
      (response) => response.data
    );
  }

  retryAttachmentScan(id: string): Promise<AttachmentSafety> {
    return this.request<DataResponse<AttachmentSafety>>(`/api/v1/admin/attachment-safety/${encodeURIComponent(id)}/retry`, { method: "POST" }).then(
      (response) => response.data
    );
  }

  operations(): Promise<OperationsSnapshot> {
    return this.request<DataResponse<OperationsSnapshot>>("/api/v1/ops").then(
      (response) => response.data
    );
  }

  platformOperations(): Promise<OperationsSnapshot> {
    return this.request<DataResponse<OperationsSnapshot>>("/api/v1/platform/ops").then(
      (response) => response.data
    );
  }

  retryOperation(resourceType: "notification" | "webhook" | "attachment_scan", id: string): Promise<void> {
    return this.request("/api/v1/ops/retry", {
      method: "POST",
      body: JSON.stringify({ resource_type: resourceType, id })
    });
  }

  conversations(): Promise<Conversation[]> {
    return this.request<ListResponse<Conversation>>("/api/v1/conversations").then(
      (response) => response.data
    );
  }

  createGuestLink(
    conversationId: string,
    input: {
      expires_in_seconds: number;
      max_uses: number;
      conversion_email?: string;
    }
  ): Promise<{
    guestLink: GuestLink;
    token: string;
    url: string;
    conversionVerificationCode?: string;
  }> {
    return this.request<{
      data?: GuestLink;
      guest_link?: GuestLink;
      token?: string;
      guest_link_token?: string;
      conversion_verification_code?: string;
    }>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/guest-links`, {
      method: "POST",
      headers: { "Idempotency-Key": operationId() },
      body: JSON.stringify(input)
    }).then((response) => {
      const guestLink = response.data || response.guest_link;
      const token = response.token || response.guest_link_token;
      const conversionVerificationCode = response.conversion_verification_code;
      const conversionRequested = Boolean(input.conversion_email);
      const validConversionCode =
        typeof conversionVerificationCode === "string" &&
        /^[A-Za-z0-9_-]{43}$/.test(conversionVerificationCode);
      if (
        !guestLink ||
        !token ||
        !guestLink.share_url ||
        (conversionRequested && !validConversionCode) ||
        (!conversionRequested && conversionVerificationCode !== undefined)
      ) {
        throw new Error("The server did not return a complete guest link.");
      }
      return {
        guestLink,
        token,
        url: guestLink.share_url,
        ...(validConversionCode
          ? { conversionVerificationCode }
          : {})
      };
    });
  }

  guestLinks(conversationId: string): Promise<GuestLink[]> {
    return this.request<ListResponse<GuestLink>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/guest-links`
    ).then((response) => response.data);
  }

  revokeGuestLink(
    conversationId: string,
    guestLinkId: string
  ): Promise<GuestLink> {
    return this.request<DataResponse<GuestLink>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/guest-links/${encodeURIComponent(guestLinkId)}`,
      { method: "DELETE" }
    ).then((response) => response.data);
  }

  calls(options: CallsQueryOptions = {}): Promise<CallsPageResponse> {
    const query = new URLSearchParams({
      scope: options.scope ?? "recent",
      limit: String(Math.max(1, Math.min(options.limit ?? 25, 100)))
    });
    if (options.media_kind) query.set("media_kind", options.media_kind);
    if (options.cursor) query.set("cursor", options.cursor);
    return this.request(`/api/v1/calls?${query.toString()}`);
  }

  files(options: FilesQueryOptions = {}): Promise<FilesPageResponse> {
    const query = new URLSearchParams({
      scope: options.scope ?? "recent",
      limit: String(Math.max(1, Math.min(options.limit ?? 25, 100)))
    });
    if (options.conversation_id) query.set("conversation_id", options.conversation_id);
    if (options.cursor) query.set("cursor", options.cursor);
    return this.request(`/api/v1/files?${query.toString()}`);
  }

  call(conversationId: string): Promise<Call | null> {
    return this.request<DataResponse<Call | null>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/call`
    ).then((response) => response.data);
  }

  startCall(conversationId: string, mediaKind: CallMediaKind): Promise<CallSessionResponse> {
    return this.request<CallSessionResponse>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls`,
      { method: "POST", body: JSON.stringify({ media_kind: mediaKind }) }
    );
  }

  joinCall(conversationId: string, callId: string): Promise<CallSessionResponse> {
    return this.request<CallSessionResponse>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/join`,
      { method: "POST" }
    );
  }

  endCall(conversationId: string, callId: string): Promise<Call> {
    return this.request<DataResponse<Call>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/end`,
      { method: "POST" }
    ).then((response) => response.data);
  }

  /** @deprecated Use the media-neutral call methods. */
  audioCall(conversationId: string): Promise<Call | null> {
    return this.call(conversationId);
  }

  /** @deprecated Use startCall with media_kind audio. */
  startAudioCall(conversationId: string): Promise<CallSessionResponse> {
    return this.startCall(conversationId, "audio");
  }

  /** @deprecated Use joinCall. */
  joinAudioCall(conversationId: string, callId: string): Promise<CallSessionResponse> {
    return this.joinCall(conversationId, callId);
  }

  /** @deprecated Use endCall. */
  endAudioCall(conversationId: string, callId: string): Promise<Call> {
    return this.endCall(conversationId, callId);
  }

  discoverPublicChannels(query = "", limit = 25, cursor?: string | null): Promise<PublicChannelDiscoveryPage> {
    const params = new URLSearchParams({ q: query, limit: String(limit) });
    if (cursor) params.set("cursor", cursor);
    return this.request(`/api/v1/channels/discover?${params.toString()}`);
  }

  joinPublicChannel(id: string): Promise<PublicChannelMembershipResponse> {
    return this.request(`/api/v1/channels/${encodeURIComponent(id)}/join`, { method: "POST" });
  }

  leavePublicChannel(id: string, version: number): Promise<PublicChannelMembershipResponse> {
    return this.request(`/api/v1/channels/${encodeURIComponent(id)}/membership`, {
      method: "DELETE",
      body: JSON.stringify({ version })
    });
  }

  conversation(id: string): Promise<Conversation> {
    return this.request<DataResponse<Conversation>>(
      `/api/v1/conversations/${encodeURIComponent(id)}`
    ).then((response) => response.data);
  }

  createConversation(input: CreateConversationInput): Promise<Conversation> {
    return this.request<DataResponse<Conversation>>("/api/v1/conversations", {
      method: "POST",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  updateConversation(id: string, input: { title?: string; visibility?: "private" | "tenant"; version: number }): Promise<Conversation> {
    return this.request<DataResponse<Conversation>>(`/api/v1/conversations/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  archiveConversation(id: string, version: number): Promise<Conversation> {
    return this.request<DataResponse<Conversation>>(`/api/v1/conversations/${encodeURIComponent(id)}/archive`, {
      method: "POST",
      body: JSON.stringify({ version })
    }).then((response) => response.data);
  }

  conversationMembers(conversationId: string): Promise<ConversationMembership[]> {
    return this.request<ListResponse<ConversationMembership>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/members`
    ).then((response) => response.data);
  }

  addConversationMember(
    conversationId: string,
    userId: string,
    role: ConversationMembership["role"] = "member"
  ): Promise<{ id: string }> {
    return this.request<DataResponse<{ id: string }>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/members`,
      { method: "POST", body: JSON.stringify({ user_id: userId, role }) }
    ).then((response) => response.data);
  }

  removeConversationMember(conversationId: string, userId: string, version: number): Promise<void> {
    return this.request(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/members/${encodeURIComponent(userId)}`,
      { method: "DELETE", body: JSON.stringify({ version }) }
    );
  }

  updateConversationMember(
    conversationId: string,
    userId: string,
    role: ConversationMembership["role"],
    version: number
  ): Promise<{ id: string; role: ConversationMembership["role"]; version: number }> {
    return this.request<DataResponse<{ id: string; role: ConversationMembership["role"]; version: number }>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/members/${encodeURIComponent(userId)}`,
      { method: "PATCH", body: JSON.stringify({ role, version }) }
    ).then((response) => response.data);
  }

  messages(
    conversationId: string,
    afterSequence = 0,
    limit = 200,
    beforeSequence?: number
  ): Promise<MessagePage> {
    const query = new URLSearchParams({
      after_sequence: String(afterSequence),
      limit: String(limit)
    });
    if (beforeSequence !== undefined) query.set("before_sequence", String(beforeSequence));
    return this.request<MessagePage>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages?${query.toString()}`
    );
  }

  messageThread(
    conversationId: string,
    messageId: string,
    beforeSequence?: number,
    limit = 50
  ): Promise<MessageThread> {
    const query = new URLSearchParams({ limit: String(Math.max(1, Math.min(limit, 100))) });
    if (beforeSequence !== undefined) query.set("before_sequence", String(beforeSequence));
    return this.request(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/thread?${query.toString()}`
    );
  }

  sendMessage(conversationId: string, input: SendMessageInput): Promise<Message> {
    const { client_message_id: idempotencyKey, ...body } = input;
    return this.request<DataResponse<Message>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages`,
      {
        method: "POST",
        headers: { "Idempotency-Key": idempotencyKey },
        body: JSON.stringify(body)
      }
    ).then((response) => response.data);
  }

  editMessage(messageId: string, body: string): Promise<Message> {
    return this.request<DataResponse<Message>>(`/api/v1/messages/${encodeURIComponent(messageId)}`, {
      method: "PATCH",
      body: JSON.stringify({ body })
    }).then((response) => response.data);
  }

  deleteMessage(messageId: string): Promise<Message> {
    return this.request<DataResponse<Message>>(`/api/v1/messages/${encodeURIComponent(messageId)}`, {
      method: "DELETE"
    }).then((response) => response.data);
  }

  searchMessages(query: string, limit = 50): Promise<Message[]> {
    const params = new URLSearchParams({ q: query, limit: String(limit) });
    return this.request<ListResponse<Message>>(`/api/v1/search?${params.toString()}`).then(
      (response) => response.data
    );
  }

  searchMessagePage(query: string, options: MessageSearchOptions = {}): Promise<MessageSearchPage> {
    const params = new URLSearchParams({
      q: query,
      limit: String(Math.max(1, Math.min(options.limit ?? 50, 200)))
    });
    if (options.cursor) params.set("cursor", options.cursor);
    if (options.conversation_id) params.set("conversation_id", options.conversation_id);
    if (options.sender_user_id) params.set("sender_user_id", options.sender_user_id);
    if (options.after) params.set("after", options.after);
    if (options.before) params.set("before", options.before);
    return this.request<MessageSearchPage>(`/api/v1/search?${params.toString()}`);
  }

  addReaction(conversationId: string, messageId: string, emoji: string): Promise<void> {
    return this.request(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/reactions`,
      { method: "POST", body: JSON.stringify({ emoji }) }
    );
  }

  removeReaction(conversationId: string, messageId: string, emoji: string): Promise<void> {
    return this.request(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/reactions/${encodeURIComponent(emoji)}`,
      { method: "DELETE" }
    );
  }

  markRead(conversationId: string, sequence: number): Promise<void> {
    return this.request(`/api/v1/conversations/${encodeURIComponent(conversationId)}/read-cursor`, {
      method: "PUT",
      body: JSON.stringify({ sequence })
    });
  }

  createAttachment(
    file: File,
    checksum: string,
    signal?: AbortSignal
  ): Promise<AttachmentIntentResponse> {
    return this.request("/api/v1/attachments", {
      method: "POST",
      signal,
      body: JSON.stringify({
        file_name: file.name,
        content_type: attachmentContentType(file),
        byte_size: file.size,
        checksum_sha256: checksum
      })
    });
  }

  completeAttachment(id: string, signal?: AbortSignal): Promise<Attachment> {
    return this.request<DataResponse<Attachment>>(
      `/api/v1/attachments/${encodeURIComponent(id)}/complete`,
      { method: "POST", signal }
    ).then((response) => response.data);
  }

  abandonAttachment(id: string): Promise<void> {
    return this.request(`/api/v1/attachments/${encodeURIComponent(id)}`, {
      method: "DELETE"
    });
  }

  attachmentDownload(id: string): Promise<AttachmentDownloadResponse> {
    return this.request(`/api/v1/attachments/${encodeURIComponent(id)}`);
  }

  attachmentStatus(
    id: string,
    signal?: AbortSignal
  ): Promise<AttachmentDownloadResponse> {
    return this.request(`/api/v1/attachments/${encodeURIComponent(id)}`, { signal });
  }

  async logout(): Promise<void> {
    this.sessionGeneration += 1;
    this.refreshController?.abort();
    try {
      await this.request("/api/v1/sessions/current", {
        method: "DELETE",
        retryAuthentication: false
      });
    } finally {
      this.updateSession(null);
    }
  }

  refreshSession(): Promise<Session | null> {
    return this.refresh();
  }

  status(): Promise<ServiceStatus> {
    return this.request<ServiceStatus>("/api/v1/status", { retryAuthentication: false });
  }

  readiness(): Promise<HealthStatus> {
    return this.request<HealthStatus>("/health/ready", { retryAuthentication: false });
  }

  private async request<T = void>(path: string, options: RequestOptions = {}): Promise<T> {
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (this.session?.access_token) {
      headers.set("Authorization", `Bearer ${this.session.access_token}`);
    }

    const response = await fetch(this.url(path), { ...options, headers });
    const shouldRetry = options.retryAuthentication !== false;
    if (response.status === 401 && shouldRetry && this.session?.refresh_token) {
      const refreshed = await this.refresh();
      if (refreshed) {
        return this.request<T>(path, { ...options, retryAuthentication: false });
      }
    }

    if (response.status === 204) {
      return undefined as T;
    }

    const contentType = response.headers.get("content-type") || "";
    const payload: unknown = contentType.includes("application/json")
      ? await response.json()
      : await response.text();

    if (!response.ok) {
      const envelope = typeof payload === "object" && payload ? (payload as ErrorEnvelope) : {};
      throw new ApiError(
        response.status,
        envelope.error?.code || "request_failed",
        envelope.error?.detail || `Request failed with status ${response.status}`,
        envelope.error?.meta
      );
    }

    return payload as T;
  }

  private async download(path: string, options: RequestOptions = {}): Promise<AuditExportFile> {
    const headers = new Headers(options.headers);
    headers.set("Accept", "text/csv");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (this.session?.access_token) {
      headers.set("Authorization", `Bearer ${this.session.access_token}`);
    }

    const response = await fetch(this.url(path), { ...options, headers });
    const shouldRetry = options.retryAuthentication !== false;
    if (response.status === 401 && shouldRetry && this.session?.refresh_token) {
      const refreshed = await this.refresh();
      if (refreshed) {
        return this.download(path, { ...options, retryAuthentication: false });
      }
    }

    if (!response.ok) {
      const contentType = response.headers.get("content-type") || "";
      const payload: unknown = contentType.includes("application/json")
        ? await response.json()
        : await response.text();
      const envelope = typeof payload === "object" && payload ? (payload as ErrorEnvelope) : {};
      throw new ApiError(
        response.status,
        envelope.error?.code || "request_failed",
        envelope.error?.detail || `Request failed with status ${response.status}`,
        envelope.error?.meta
      );
    }

    return {
      blob: await response.blob(),
      filename: attachmentFilename(response.headers.get("content-disposition")),
      count: nonNegativeHeaderInteger(response.headers.get("x-export-row-count")),
      truncated: response.headers.get("x-export-truncated") === "true"
    };
  }

  private refresh(): Promise<Session | null> {
    if (!this.refreshPromise) {
      this.refreshPromise = this.performRefresh().finally(() => {
        this.refreshPromise = null;
        this.refreshController = null;
      });
    }
    return this.refreshPromise;
  }

  private async performRefresh(): Promise<Session | null> {
    const refreshToken = this.session?.refresh_token;
    if (!refreshToken) return null;
    const generation = this.sessionGeneration;
    const controller = new AbortController();
    this.refreshController = controller;

    // Network failures and server outages deliberately propagate without
    // erasing the local session. A later request or online event can retry.
    const response = await fetch(this.url("/api/v1/sessions/refresh"), {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ refresh_token: refreshToken }),
      signal: controller.signal
    });
    if (!response.ok) {
      if ([400, 401, 403].includes(response.status)) {
        this.updateSession(null);
        return null;
      }
      throw new Error(`Session refresh is temporarily unavailable (${response.status})`);
    }
    const session = withReceivedAt((await response.json()) as Session);
    if (
      generation !== this.sessionGeneration ||
      this.session?.refresh_token !== refreshToken
    ) {
      return null;
    }
    this.updateSession(session);
    return session;
  }

  private updateSession(session: Session | null): void {
    this.setSession(session);
    this.onSession(session);
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }
}

export class GuestApiClient {
  private session: GuestSession | null;
  private refreshPromise: Promise<GuestSession | null> | null = null;

  constructor(
    private readonly baseUrl: string,
    initialSession: GuestSession | null,
    private readonly onSession: (
      session: GuestSession | null,
      reason?: "access_ended" | "logout"
    ) => void
  ) {
    this.session = initialSession;
  }

  setSession(session: GuestSession | null): void {
    this.session = session;
  }

  previewGuestLink(token: string): Promise<GuestLinkPreview> {
    return this.request<DataResponse<GuestLinkPreview> | GuestLinkPreview>(
      "/api/v1/guest-links/preview",
      {
        method: "POST",
        body: JSON.stringify({ token }),
        retryAuthentication: false
      }
    ).then(unwrapData);
  }

  joinGuest(input: {
    token: string;
    display_name: string;
    device: { name: string; platform: "web" };
  }): Promise<GuestSession> {
    return this.request<unknown>("/api/v1/guest-sessions", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then((payload) => {
      const session = normalizeGuestSession(payload);
      this.updateSession(session);
      return session;
    });
  }

  conversation(): Promise<Conversation> {
    return this.request<DataResponse<Conversation> | Conversation>(
      "/api/v1/guest/conversation"
    ).then(unwrapData);
  }

  conversationMembers(): Promise<ConversationMembership[]> {
    return this.request<ListResponse<ConversationMembership> | ConversationMembership[]>(
      "/api/v1/guest/conversation/members"
    ).then(unwrapList);
  }

  messages(afterSequence = 0, limit = 200): Promise<MessagePage> {
    const query = new URLSearchParams({
      after_sequence: String(afterSequence),
      limit: String(limit)
    });
    return this.request(`/api/v1/guest/conversation/messages?${query.toString()}`);
  }

  sendMessage(input: SendMessageInput): Promise<Message> {
    const { client_message_id: idempotencyKey, ...body } = input;
    return this.request<DataResponse<Message> | Message>(
      "/api/v1/guest/conversation/messages",
      {
        method: "POST",
        headers: { "Idempotency-Key": idempotencyKey },
        body: JSON.stringify(body)
      }
    ).then(unwrapData);
  }

  markRead(sequence: number): Promise<void> {
    return this.request("/api/v1/guest/conversation/read-cursor", {
      method: "PUT",
      body: JSON.stringify({ sequence })
    });
  }

  socketTicket(): Promise<{ ticket: string; expires_in: number }> {
    return this.request<
      DataResponse<{ ticket: string; expires_in: number }> |
      { ticket: string; expires_in: number }
    >("/api/v1/guest/socket-tickets", { method: "POST" }).then(unwrapData);
  }

  call(): Promise<Call | null> {
    return this.request<DataResponse<Call | null> | Call | null>(
      "/api/v1/guest/conversation/call"
    ).then(unwrapNullableData);
  }

  startCall(_conversationId: string, mediaKind: CallMediaKind): Promise<CallSessionResponse> {
    return this.request("/api/v1/guest/conversation/calls", {
      method: "POST",
      body: JSON.stringify({ media_kind: mediaKind })
    });
  }

  joinCall(_conversationId: string, callId: string): Promise<CallSessionResponse> {
    return this.request(
      `/api/v1/guest/conversation/calls/${encodeURIComponent(callId)}/join`,
      { method: "POST" }
    );
  }

  endCall(_conversationId: string, callId: string): Promise<Call> {
    return this.request<DataResponse<Call> | Call>(
      `/api/v1/guest/conversation/calls/${encodeURIComponent(callId)}/end`,
      { method: "POST" }
    ).then(unwrapData);
  }

  convertAccount(input: {
    email: string;
    verification_code: string;
    password: string;
  }): Promise<{ session: Session; conversation: Conversation }> {
    return this.request<unknown>("/api/v1/guest/account", {
      method: "POST",
      body: JSON.stringify(input)
    }).then(normalizeAccountConversion);
  }

  async logout(): Promise<void> {
    try {
      await this.request("/api/v1/guest/sessions/current", {
        method: "DELETE",
        retryAuthentication: false
      });
    } finally {
      this.updateSession(null, "logout");
    }
  }

  private async request<T = void>(path: string, options: RequestOptions = {}): Promise<T> {
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (this.session?.access_token) {
      headers.set("Authorization", `Bearer ${this.session.access_token}`);
    }

    const response = await fetch(this.url(path), { ...options, headers });
    const shouldRetry = options.retryAuthentication !== false;
    if (response.status === 401 && shouldRetry && this.session?.refresh_token) {
      const refreshed = await this.refresh();
      if (refreshed) {
        return this.request<T>(path, { ...options, retryAuthentication: false });
      }
    }
    if (response.status === 204) return undefined as T;

    const contentType = response.headers.get("content-type") || "";
    const payload: unknown = contentType.includes("application/json")
      ? await response.json()
      : await response.text();

    if (!response.ok) {
      const envelope = typeof payload === "object" && payload ? (payload as ErrorEnvelope) : {};
      throw new ApiError(
        response.status,
        envelope.error?.code || "request_failed",
        envelope.error?.detail || `Request failed with status ${response.status}`,
        envelope.error?.meta
      );
    }
    return payload as T;
  }

  private refresh(): Promise<GuestSession | null> {
    if (!this.refreshPromise) {
      this.refreshPromise = this.performRefresh().finally(() => {
        this.refreshPromise = null;
      });
    }
    return this.refreshPromise;
  }

  private async performRefresh(): Promise<GuestSession | null> {
    const refreshToken = this.session?.refresh_token;
    if (!refreshToken) return null;
    const response = await fetch(this.url("/api/v1/guest/sessions/refresh"), {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ refresh_token: refreshToken })
    });
    if (!response.ok) {
      if ([400, 401, 403].includes(response.status)) {
        this.updateSession(null, "access_ended");
        return null;
      }
      throw new Error(`Guest session refresh is temporarily unavailable (${response.status})`);
    }

    const previous = this.session;
    if (!previous || previous.refresh_token !== refreshToken) return null;
    const payload = await response.json();
    const refreshed = normalizeGuestSession({
      ...payload,
      conversation: readObject(payload)?.conversation || previous.conversation,
      capabilities: readObject(payload)?.capabilities || previous.capabilities,
      admission: readObject(payload)?.admission || previous.admission
    });
    this.updateSession(refreshed);
    return refreshed;
  }

  private updateSession(
    session: GuestSession | null,
    reason?: "access_ended" | "logout"
  ): void {
    this.session = session;
    if (reason) {
      this.onSession(session, reason);
    } else {
      this.onSession(session);
    }
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }
}

function unwrapData<T>(payload: DataResponse<T> | T): T {
  if (payload && typeof payload === "object" && "data" in payload) {
    return (payload as DataResponse<T>).data;
  }
  return payload as T;
}

function unwrapNullableData<T>(payload: DataResponse<T | null> | T | null): T | null {
  return payload === null ? null : unwrapData(payload);
}

function unwrapList<T>(payload: ListResponse<T> | T[]): T[] {
  return Array.isArray(payload) ? payload : payload.data;
}

function normalizeGuestSession(payload: unknown): GuestSession {
  const root = readObject(unwrapUnknownData(payload));
  const authentication =
    readObject(root?.authentication) ||
    readObject(root?.auth) ||
    readObject(root?.session) ||
    root;
  const conversation = readObject(root?.conversation || authentication?.conversation);
  const capabilities = readObject(root?.capabilities || authentication?.capabilities);
  if (
    !authentication ||
    typeof authentication.access_token !== "string" ||
    typeof authentication.refresh_token !== "string" ||
    !readObject(authentication.tenant) ||
    !readObject(authentication.user) ||
    !readObject(authentication.device) ||
    !conversation ||
    !capabilities
  ) {
    throw new Error("The server did not return a complete guest session.");
  }
  return withReceivedAt({
    ...(authentication as unknown as Session),
    conversation: conversation as unknown as Conversation,
    capabilities: {
      allow_audio_calls: capabilities.allow_audio_calls === true,
      allow_video_calls: capabilities.allow_video_calls === true,
      conversion_enabled: capabilities.conversion_enabled === true,
      email_hint:
        typeof capabilities.email_hint === "string"
          ? capabilities.email_hint
          : null
    },
    admission: readObject(root?.admission) as unknown as GuestSession["admission"]
  });
}

function normalizeAccountConversion(payload: unknown): {
  session: Session;
  conversation: Conversation;
} {
  const root = readObject(unwrapUnknownData(payload));
  const authentication =
    readObject(root?.authentication) ||
    readObject(root?.auth) ||
    readObject(root?.session) ||
    root;
  const conversation = readObject(root?.conversation);
  if (
    !authentication ||
    typeof authentication.access_token !== "string" ||
    typeof authentication.refresh_token !== "string" ||
    !conversation
  ) {
    throw new Error("The server did not return a complete account session.");
  }
  return {
    session: withReceivedAt(authentication as unknown as Session),
    conversation: conversation as unknown as Conversation
  };
}

function unwrapUnknownData(payload: unknown): unknown {
  const object = readObject(payload);
  return object && "data" in object ? object.data : payload;
}

function readObject(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object"
    ? value as Record<string, unknown>
    : null;
}

function attachmentFilename(contentDisposition: string | null): string {
  const fallback = "k-comms-audit.csv";
  if (!contentDisposition) return fallback;

  const encoded = contentDisposition.match(/filename\*=UTF-8''([^;]+)/i)?.[1];
  const basic = contentDisposition.match(/filename="?([^";]+)"?/i)?.[1];
  try {
    const candidate = encoded ? decodeURIComponent(encoded) : basic;
    return candidate && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.csv$/i.test(candidate)
      ? candidate
      : fallback;
  } catch {
    return fallback;
  }
}

function nonNegativeHeaderInteger(value: string | null): number {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
}

export async function sha256(file: File): Promise<string> {
  const digest = await window.crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function uploadToPresignedTarget(
  descriptor: UploadDescriptor,
  file: File,
  signal?: AbortSignal
): Promise<void> {
  const url = validatedPresignedUrl(descriptor);

  let body: BodyInit = file;
  const headers = new Headers(descriptor.headers);
  if (descriptor.fields && Object.keys(descriptor.fields).length > 0) {
    const form = new FormData();
    Object.entries(descriptor.fields).forEach(([key, value]) => form.append(key, value));
    form.append("file", file);
    body = form;
  } else if (!headers.has("content-type")) {
    headers.set("content-type", attachmentContentType(file));
  }

  const response = await fetch(url, {
    method: descriptor.method || (descriptor.fields ? "POST" : "PUT"),
    headers,
    body,
    signal
  });
  if (!response.ok) throw new Error(`Object upload failed with status ${response.status}`);
}

export function downloadUrl(descriptor?: UploadDescriptor): string | null {
  if (!descriptor) return null;
  try {
    return validatedPresignedUrl(descriptor);
  } catch {
    return null;
  }
}

function validatedPresignedUrl(descriptor: UploadDescriptor): string {
  const raw = descriptor.url || descriptor.upload_url || descriptor.href;
  if (!raw) throw new Error("The object store did not return a URL");
  if (!descriptor.approved_origin) throw new Error("The object store did not identify an approved origin");

  const target = new URL(raw, window.location.origin);
  const approved = new URL(descriptor.approved_origin, window.location.origin);
  if (target.username || target.password) throw new Error("Object-store URLs cannot contain credentials");
  if (target.origin !== approved.origin) throw new Error("The object-store URL did not match its approved origin");

  const localDevelopment =
    target.protocol === "http:" &&
    ["localhost", "127.0.0.1", "[::1]"].includes(target.hostname) &&
    ["localhost", "127.0.0.1", "[::1]"].includes(approved.hostname);
  if (target.protocol !== "https:" && !localDevelopment) {
    throw new Error("Object-store URLs must use HTTPS");
  }
  return target.toString();
}

function attachmentContentType(file: File): string {
  if (file.type) return file.type;
  const extension = file.name.toLowerCase().split(".").pop();
  const known: Record<string, string> = {
    csv: "text/csv",
    gif: "image/gif",
    jpeg: "image/jpeg",
    jpg: "image/jpeg",
    json: "application/json",
    md: "text/markdown",
    pdf: "application/pdf",
    png: "image/png",
    svg: "image/svg+xml",
    txt: "text/plain",
    webp: "image/webp",
    zip: "application/zip"
  };
  return (extension && known[extension]) || "application/octet-stream";
}

function withReceivedAt<T extends Session>(session: T): T {
  return { ...session, received_at: Date.now() };
}

function operationId(): string {
  return globalThis.crypto.randomUUID
    ? globalThis.crypto.randomUUID()
    : `web-operation-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
