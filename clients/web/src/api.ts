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
  AttachmentThumbnailIntent,
  Conversation,
  ConversationMembership,
  DeletionRequest,
  Device,
  DirectoryPeoplePage,
  DirectConversationResponse,
  HealthStatus,
  Invitation,
  InAppNotification,
  InAppNotificationPage,
  LegalHold,
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
  InstantRoomPreview,
  InstantRoomResult,
  PublicChannelDiscoveryPage,
  PublicChannelMembershipResponse,
  PushSubscriptionConfig,
  PushSubscriptionInput,
  PushSubscriptionRecord,
  AuditEvent,
  RetentionPolicy,
  RetainedSenderLabel,
  Session,
  ServiceAccount,
  ServiceStatus,
  TenantAdministration,
  UserRole,
  User,
  WebhookDelivery,
  WebhookEndpoint
} from "./types";
import { ApiError, retryAfterSeconds } from "./api/errors";
import {
  normalizeInstantRoomPreview,
  normalizeInstantRoomResult,
  unwrapUnknownData
} from "./api/guest/normalizers";
import { resolveSenderLabelBatches } from "./api/senderLabels";
import {
  sameMemberSessionIdentity,
  withReceivedAt
} from "./api/sessionIdentity";
import { fetchWithApiDeadline } from "./api/transport/deadline";
import {
  attachmentContentType,
  attachmentFilename,
  nonNegativeHeaderInteger
} from "./api/uploads";
import type {
  ApiDownload,
  ApiRequest,
  ApiRequestOptions,
  AuditExportInput,
  AuditExportFile,
  BootstrapInput,
  CreateConversationInput,
  CreateServiceAccountInput,
  LoginInput,
  SendMessageInput,
  UpdateTenantInput
} from "./api/contracts";
import type { AccountsApi, RoomsApi, AdministrationApi, NotificationsApi, IntegrationsApi, CallsApi, MessagingApi, FilesApi, SystemApi } from "./api/domain-types";
import { createAccountsApi } from "./api/domains/accounts";
import { createRoomsApi } from "./api/domains/rooms";
import { createAdministrationApi } from "./api/domains/administration";
import { createNotificationsApi } from "./api/domains/notifications";
import { createIntegrationsApi } from "./api/domains/integrations";
import { createCallsApi } from "./api/domains/calls";
import { createMessagingApi } from "./api/domains/messaging";
import { createFilesApi } from "./api/domains/files";
import { createSystemApi } from "./api/domains/system";
export type { AuditExportFile, AuditExportInput, BootstrapInput, CreateConversationInput, CreateServiceAccountInput, LoginInput, SendMessageInput, UpdateTenantInput } from "./api/contracts";
export { ApiError } from "./api/errors";
export { GuestApiClient } from "./api/guest/GuestApiClient";
export {
  loadStoredGuestSession,
  loadStoredSession,
  storeGuestSession,
  storeSession
} from "./api/sessionStorage";
export {
  downloadUrl,
  isApprovedPrivateLanObjectUrl,
  sha256,
  sha256Blob,
  uploadToPresignedTarget
} from "./api/uploads";



interface ErrorEnvelope {
  error?: {
    code?: string;
    detail?: string;
    meta?: unknown;
  };
}

type RequestOptions = ApiRequestOptions;

export class ApiClient {
  private session: Session | null;
  private refreshPromise: Promise<Session | null> | null = null;
  private refreshController: AbortController | null = null;
  private sessionGeneration = 0;
  private readonly accountsApi: AccountsApi;
  private readonly roomsApi: RoomsApi;
  private readonly administrationApi: AdministrationApi;
  private readonly notificationsApi: NotificationsApi;
  private readonly integrationsApi: IntegrationsApi;
  private readonly callsApi: CallsApi;
  private readonly messagingApi: MessagingApi;
  private readonly filesApi: FilesApi;
  private readonly systemApi: SystemApi;

  constructor(
    private readonly baseUrl: string,
    initialSession: Session | null,
    private readonly onSession: (session: Session | null) => void
  ) {
    this.session = initialSession;

    const request: ApiRequest = (path, options) => this.request(path, options);
    const download: ApiDownload = (path, options) => this.download(path, options);
    this.accountsApi = createAccountsApi(request, { withReceivedAt });
    this.roomsApi = createRoomsApi(request, {
      normalizeInstantRoomPreview,
      normalizeInstantRoomResult,
      operationId,
      unwrapUnknownData
    });
    this.administrationApi = createAdministrationApi(request, download, { operationId });
    this.notificationsApi = createNotificationsApi(request);
    this.integrationsApi = createIntegrationsApi(request);
    this.callsApi = createCallsApi(request);
    this.messagingApi = createMessagingApi(request, { resolveSenderLabelBatches });
    this.filesApi = createFilesApi(request, { attachmentContentType });
    this.systemApi = createSystemApi(request);
  }

  setSession(session: Session | null): void {
    const credentialsChanged =
      this.session?.access_token !== session?.access_token ||
      this.session?.refresh_token !== session?.refresh_token;
    if (!sameMemberSessionIdentity(this.session, session)) {
      this.sessionGeneration += 1;
    }
    if (credentialsChanged) {
      this.refreshController?.abort();
    }
    this.session = session;
  }

  bootstrap(input: BootstrapInput): Promise<Session & { conversation: Conversation }>{
    return this.accountsApi.bootstrap(input);
  }

  login(input: LoginInput): Promise<Session>{
    return this.accountsApi.login(input);
  }

  requestPasswordRecovery(input: { tenant_slug: string; email: string }): Promise<void>{
    return this.accountsApi.requestPasswordRecovery(input);
  }

  resetPassword(input: { token: string; new_password: string }): Promise<void>{
    return this.accountsApi.resetPassword(input);
  }

  acceptInvitation(input: { token: string; display_name: string; password: string }): Promise<User>{
    return this.accountsApi.acceptInvitation(input);
  }

  me(): Promise<MeResponse>{
    return this.accountsApi.me();
  }

  updateProfile(input: { display_name: string }): Promise<User>{
    return this.accountsApi.updateProfile(input);
  }

  changePassword(input: { current_password: string; new_password: string }): Promise<void>{
    return this.accountsApi.changePassword(input);
  }

  stepUp(currentPassword: string): Promise<{ step_up_at: string }>{
    return this.accountsApi.stepUp(currentPassword);
  }

  socketTicket(): Promise<{ ticket: string; expires_in: number }>{
    return this.accountsApi.socketTicket();
  }

  devices(): Promise<Device[]>{
    return this.accountsApi.devices();
  }

  revokeDevice(id: string): Promise<void>{
    return this.accountsApi.revokeDevice(id);
  }

  sessions(): Promise<AccountSession[]>{
    return this.accountsApi.sessions();
  }

  revokeSession(id: string): Promise<void>{
    return this.accountsApi.revokeSession(id);
  }

  users(): Promise<User[]>{
    return this.accountsApi.users();
  }

  directoryUsers(
    query = "",
    limit = 25,
    cursor?: string | null
  ): Promise<DirectoryPeoplePage>{
    return this.accountsApi.directoryUsers(query, limit, cursor);
  }

  directConversation(userId: string): Promise<DirectConversationResponse>{
    return this.accountsApi.directConversation(userId);
  }

  createInstantRoom(
    input: {
      display_name?: string;
      title?: string;
      device?: { name: string; platform: "web" };
    },
    idempotencyKey: string
  ): Promise<InstantRoomResult>{
    return this.roomsApi.createInstantRoom(input, idempotencyKey);
  }

  previewInstantRoom(token: string): Promise<InstantRoomPreview>{
    return this.roomsApi.previewInstantRoom(token);
  }

  joinInstantRoom(input: {
    token: string;
    display_name?: string;
    device?: { name: string; platform: "web" };
  }, idempotencyKey: string): Promise<InstantRoomResult>{
    return this.roomsApi.joinInstantRoom(input, idempotencyKey);
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
  }>{
    return this.roomsApi.createGuestLink(conversationId, input);
  }

  guestLinks(conversationId: string): Promise<GuestLink[]>{
    return this.roomsApi.guestLinks(conversationId);
  }

  revokeGuestLink(
    conversationId: string,
    guestLinkId: string
  ): Promise<GuestLink>{
    return this.roomsApi.revokeGuestLink(conversationId, guestLinkId);
  }

  adminUsers(): Promise<User[]>{
    return this.administrationApi.adminUsers();
  }

  updateAdminUser(id: string, input: { role?: UserRole; status?: string; display_name?: string; reason?: string; version: number }): Promise<User>{
    return this.administrationApi.updateAdminUser(id, input);
  }

  adminUserSessions(userId: string): Promise<AccountSession[]>{
    return this.administrationApi.adminUserSessions(userId);
  }

  adminRevokeSession(userId: string, sessionId: string, reason?: string): Promise<void>{
    return this.administrationApi.adminRevokeSession(userId, sessionId, reason);
  }

  tenantAdministration(): Promise<TenantAdministration>{
    return this.administrationApi.tenantAdministration();
  }

  updateTenantAdministration(input: UpdateTenantInput): Promise<TenantAdministration>{
    return this.administrationApi.updateTenantAdministration(input);
  }

  invitations(): Promise<Invitation[]>{
    return this.administrationApi.invitations();
  }

  createInvitation(input: { email: string; role: Exclude<UserRole, "owner"> }): Promise<{ invitation: Invitation; invitationToken?: string | null }>{
    return this.administrationApi.createInvitation(input);
  }

  revokeInvitation(id: string, version: number, reason?: string): Promise<Invitation>{
    return this.administrationApi.revokeInvitation(id, version, reason);
  }

  auditEvents(limit = 100): Promise<AuditEvent[]>{
    return this.administrationApi.auditEvents(limit);
  }

  exportAuditEvents(input: AuditExportInput = {}): Promise<AuditExportFile>{
    return this.administrationApi.exportAuditEvents(input);
  }

  moderationCases(): Promise<ModerationCase[]>{
    return this.administrationApi.moderationCases();
  }

  createModerationCase(input: { subject_user_id?: string; conversation_id?: string; message_id?: string; category: string; summary: string; details?: string; priority?: string }): Promise<ModerationCase>{
    return this.administrationApi.createModerationCase(input);
  }

  addModerationAction(id: string, input: { action_type: string; note: string; version: number }): Promise<ModerationCase>{
    return this.administrationApi.addModerationAction(id, input);
  }

  retentionPolicies(): Promise<RetentionPolicy[]>{
    return this.administrationApi.retentionPolicies();
  }

  createRetentionPolicy(input: { name: string; retention_days: number; delete_attachments: boolean }): Promise<RetentionPolicy>{
    return this.administrationApi.createRetentionPolicy(input);
  }

  updateRetentionPolicy(id: string, input: { status: "active" | "disabled"; version: number; reason: string }): Promise<RetentionPolicy>{
    return this.administrationApi.updateRetentionPolicy(id, input);
  }

  legalHolds(): Promise<LegalHold[]>{
    return this.administrationApi.legalHolds();
  }

  createLegalHold(input: {
    name: string;
    reason: string;
    scope_type: "tenant" | "user" | "conversation";
    target_id?: string;
  }): Promise<LegalHold>{
    return this.administrationApi.createLegalHold(input);
  }

  releaseLegalHold(id: string, version: number, releaseReason: string): Promise<LegalHold>{
    return this.administrationApi.releaseLegalHold(id, version, releaseReason);
  }

  deletionRequests(): Promise<DeletionRequest[]>{
    return this.administrationApi.deletionRequests();
  }

  createDeletionRequest(input: { target_type: "user" | "conversation" | "message"; target_id: string; reason: string }): Promise<DeletionRequest>{
    return this.administrationApi.createDeletionRequest(input);
  }

  updateDeletionRequest(id: string, input: { status: string; version: number; transition_reason: string }): Promise<DeletionRequest>{
    return this.administrationApi.updateDeletionRequest(id, input);
  }

  operations(): Promise<OperationsSnapshot>{
    return this.administrationApi.operations();
  }

  platformOperations(): Promise<OperationsSnapshot>{
    return this.administrationApi.platformOperations();
  }

  retryOperation(resourceType: "notification" | "webhook" | "attachment_scan", id: string): Promise<void>{
    return this.administrationApi.retryOperation(resourceType, id);
  }

  notificationPreference(): Promise<NotificationPreference>{
    return this.notificationsApi.notificationPreference();
  }

  updateNotificationPreference(input: Pick<NotificationPreference, "email_enabled" | "push_enabled" | "in_app_enabled" | "muted_event_types">): Promise<NotificationPreference>{
    return this.notificationsApi.updateNotificationPreference(input);
  }

  notifications(): Promise<NotificationIntent[]>{
    return this.notificationsApi.notifications();
  }

  notificationAttempts(): Promise<NotificationAttempt[]>{
    return this.notificationsApi.notificationAttempts();
  }

  retryNotification(id: string): Promise<NotificationIntent>{
    return this.notificationsApi.retryNotification(id);
  }

  pushSubscriptionConfig(): Promise<PushSubscriptionConfig>{
    return this.notificationsApi.pushSubscriptionConfig();
  }

  pushSubscriptions(): Promise<PushSubscriptionRecord[]>{
    return this.notificationsApi.pushSubscriptions();
  }

  registerPushSubscription(input: PushSubscriptionInput): Promise<{ data: PushSubscriptionRecord; replayed: boolean }>{
    return this.notificationsApi.registerPushSubscription(input);
  }

  revokePushSubscription(id: string): Promise<PushSubscriptionRecord>{
    return this.notificationsApi.revokePushSubscription(id);
  }

  inAppNotifications(limit = 50): Promise<InAppNotificationPage>{
    return this.notificationsApi.inAppNotifications(limit);
  }

  inAppUnreadCount(): Promise<number>{
    return this.notificationsApi.inAppUnreadCount();
  }

  markInAppNotificationRead(id: string): Promise<InAppNotification>{
    return this.notificationsApi.markInAppNotificationRead(id);
  }

  dismissInAppNotification(id: string): Promise<InAppNotification>{
    return this.notificationsApi.dismissInAppNotification(id);
  }

  markAllInAppNotificationsRead(): Promise<{ updated_count: number; unread_count: number }>{
    return this.notificationsApi.markAllInAppNotificationsRead();
  }

  webhooks(): Promise<WebhookEndpoint[]>{
    return this.integrationsApi.webhooks();
  }

  createWebhook(input: { name: string; url: string; event_types: string[] }): Promise<{ endpoint: WebhookEndpoint; secret: string }>{
    return this.integrationsApi.createWebhook(input);
  }

  rotateWebhookSecret(id: string, reason?: string): Promise<{ endpoint: WebhookEndpoint; secret: string }>{
    return this.integrationsApi.rotateWebhookSecret(id, reason);
  }

  disableWebhook(id: string, reason?: string): Promise<void>{
    return this.integrationsApi.disableWebhook(id, reason);
  }

  webhookDeliveries(): Promise<WebhookDelivery[]>{
    return this.integrationsApi.webhookDeliveries();
  }

  serviceAccounts(): Promise<ServiceAccount[]>{
    return this.integrationsApi.serviceAccounts();
  }

  createServiceAccount(input: CreateServiceAccountInput): Promise<{ account: ServiceAccount; credential: string }>{
    return this.integrationsApi.createServiceAccount(input);
  }

  rotateServiceAccount(id: string, version: number, reason: string): Promise<{ account: ServiceAccount; credential: string }>{
    return this.integrationsApi.rotateServiceAccount(id, version, reason);
  }

  revokeServiceAccount(id: string, version: number, reason: string): Promise<ServiceAccount>{
    return this.integrationsApi.revokeServiceAccount(id, version, reason);
  }

  replayWebhookDelivery(id: string): Promise<WebhookDelivery>{
    return this.integrationsApi.replayWebhookDelivery(id);
  }

  calls(options: CallsQueryOptions = {}): Promise<CallsPageResponse>{
    return this.callsApi.calls(options);
  }

  call(conversationId: string): Promise<Call | null>{
    return this.callsApi.call(conversationId);
  }

  startCall(conversationId: string, mediaKind: CallMediaKind): Promise<CallSessionResponse>{
    return this.callsApi.startCall(conversationId, mediaKind);
  }

  joinCall(conversationId: string, callId: string): Promise<CallSessionResponse>{
    return this.callsApi.joinCall(conversationId, callId);
  }

  endCall(conversationId: string, callId: string): Promise<Call>{
    return this.callsApi.endCall(conversationId, callId);
  }

  audioCall(conversationId: string): Promise<Call | null>{
    return this.callsApi.audioCall(conversationId);
  }

  startAudioCall(conversationId: string): Promise<CallSessionResponse>{
    return this.callsApi.startAudioCall(conversationId);
  }

  joinAudioCall(conversationId: string, callId: string): Promise<CallSessionResponse>{
    return this.callsApi.joinAudioCall(conversationId, callId);
  }

  endAudioCall(conversationId: string, callId: string): Promise<Call>{
    return this.callsApi.endAudioCall(conversationId, callId);
  }

  conversations(): Promise<Conversation[]>{
    return this.messagingApi.conversations();
  }

  discoverPublicChannels(query = "", limit = 25, cursor?: string | null): Promise<PublicChannelDiscoveryPage>{
    return this.messagingApi.discoverPublicChannels(query, limit, cursor);
  }

  joinPublicChannel(id: string): Promise<PublicChannelMembershipResponse>{
    return this.messagingApi.joinPublicChannel(id);
  }

  leavePublicChannel(id: string, version: number): Promise<PublicChannelMembershipResponse>{
    return this.messagingApi.leavePublicChannel(id, version);
  }

  conversation(id: string): Promise<Conversation>{
    return this.messagingApi.conversation(id);
  }

  createConversation(input: CreateConversationInput): Promise<Conversation>{
    return this.messagingApi.createConversation(input);
  }

  updateConversation(id: string, input: { title?: string; visibility?: "private" | "tenant"; version: number }): Promise<Conversation>{
    return this.messagingApi.updateConversation(id, input);
  }

  archiveConversation(id: string, version: number): Promise<Conversation>{
    return this.messagingApi.archiveConversation(id, version);
  }

  conversationMembers(conversationId: string): Promise<ConversationMembership[]>{
    return this.messagingApi.conversationMembers(conversationId);
  }

  addConversationMember(
    conversationId: string,
    userId: string,
    role: ConversationMembership["role"] = "member"
  ): Promise<{ id: string }>{
    return this.messagingApi.addConversationMember(conversationId, userId, role);
  }

  removeConversationMember(conversationId: string, userId: string, version: number): Promise<void>{
    return this.messagingApi.removeConversationMember(conversationId, userId, version);
  }

  updateConversationMember(
    conversationId: string,
    userId: string,
    role: ConversationMembership["role"],
    version: number
  ): Promise<{ id: string; role: ConversationMembership["role"]; version: number }>{
    return this.messagingApi.updateConversationMember(conversationId, userId, role, version);
  }

  messages(
    conversationId: string,
    afterSequence = 0,
    limit = 200,
    beforeSequence?: number
  ): Promise<MessagePage>{
    return this.messagingApi.messages(conversationId, afterSequence, limit, beforeSequence);
  }

  messageSenderLabels(
    conversationId: string,
    messageIds: string[]
  ): Promise<RetainedSenderLabel[]>{
    return this.messagingApi.messageSenderLabels(conversationId, messageIds);
  }

  messageThread(
    conversationId: string,
    messageId: string,
    beforeSequence?: number,
    limit = 50
  ): Promise<MessageThread>{
    return this.messagingApi.messageThread(conversationId, messageId, beforeSequence, limit);
  }

  sendMessage(conversationId: string, input: SendMessageInput): Promise<Message>{
    return this.messagingApi.sendMessage(conversationId, input);
  }

  editMessage(messageId: string, body: string): Promise<Message>{
    return this.messagingApi.editMessage(messageId, body);
  }

  deleteMessage(messageId: string): Promise<Message>{
    return this.messagingApi.deleteMessage(messageId);
  }

  searchMessages(query: string, limit = 50): Promise<Message[]>{
    return this.messagingApi.searchMessages(query, limit);
  }

  searchMessagePage(query: string, options: MessageSearchOptions = {}): Promise<MessageSearchPage>{
    return this.messagingApi.searchMessagePage(query, options);
  }

  addReaction(conversationId: string, messageId: string, emoji: string): Promise<void>{
    return this.messagingApi.addReaction(conversationId, messageId, emoji);
  }

  removeReaction(conversationId: string, messageId: string, emoji: string): Promise<void>{
    return this.messagingApi.removeReaction(conversationId, messageId, emoji);
  }

  markRead(conversationId: string, sequence: number): Promise<void>{
    return this.messagingApi.markRead(conversationId, sequence);
  }

  files(options: FilesQueryOptions = {}): Promise<FilesPageResponse>{
    return this.filesApi.files(options);
  }

  attachmentSafety(): Promise<AttachmentSafety[]>{
    return this.filesApi.attachmentSafety();
  }

  retryAttachmentScan(id: string): Promise<AttachmentSafety>{
    return this.filesApi.retryAttachmentScan(id);
  }

  createAttachment(
    file: File,
    checksum: string,
    signal?: AbortSignal,
    thumbnail?: AttachmentThumbnailIntent
  ): Promise<AttachmentIntentResponse>{
    return this.filesApi.createAttachment(file, checksum, signal, thumbnail);
  }

  completeAttachment(id: string, signal?: AbortSignal): Promise<Attachment>{
    return this.filesApi.completeAttachment(id, signal);
  }

  abandonAttachment(id: string): Promise<void>{
    return this.filesApi.abandonAttachment(id);
  }

  attachmentDownload(id: string): Promise<AttachmentDownloadResponse>{
    return this.filesApi.attachmentDownload(id);
  }

  attachmentStatus(
    id: string,
    signal?: AbortSignal
  ): Promise<AttachmentDownloadResponse>{
    return this.filesApi.attachmentStatus(id, signal);
  }

  status(): Promise<ServiceStatus>{
    return this.systemApi.status();
  }

  readiness(): Promise<HealthStatus>{
    return this.systemApi.readiness();
  }

  async logout(): Promise<void> {
    const revocation = this.session
      ? this.request("/api/v1/sessions/current", {
        method: "DELETE",
        keepalive: true,
        retryAuthentication: false
      }).catch(() => undefined)
      : Promise.resolve();
    this.updateSession(null);
    await revocation;
  }

  refreshSession(): Promise<Session | null> {
    return this.refresh();
  }

  private async request<T = void>(path: string, options: RequestOptions = {}): Promise<T> {
    const requestGeneration = this.sessionGeneration;
    const requestSession = this.session;
    const requestAccessToken = this.session?.access_token;
    const requestRefreshToken = this.session?.refresh_token;
    const authenticatedRequest =
      !options.skipAuthentication && Boolean(requestAccessToken);
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (!options.skipAuthentication && requestAccessToken) {
      headers.set("Authorization", `Bearer ${requestAccessToken}`);
    }

    const { response, body: payload } = await fetchWithApiDeadline(
      this.url(path),
      { ...options, headers },
      async (result) => {
        if (result.status === 204) return undefined;
        const contentType = result.headers.get("content-type") || "";
        return contentType.includes("application/json")
          ? result.json()
          : result.text();
      }
    );
    const shouldRetry = options.retryAuthentication !== false;
    if (
      response.status === 401 &&
      shouldRetry &&
      requestRefreshToken &&
      this.sessionMatches(
        requestGeneration,
        requestSession
      )
    ) {
      if (this.session?.refresh_token !== requestRefreshToken) {
        return this.request<T>(path, {
          ...options,
          retryAuthentication: false
        });
      }
      const refreshed = await this.refresh();
      if (
        refreshed &&
        this.session?.access_token === refreshed.access_token &&
        this.session?.refresh_token === refreshed.refresh_token
      ) {
        return this.request<T>(path, { ...options, retryAuthentication: false });
      }
    }

    if (response.status === 204) {
      if (
        authenticatedRequest &&
        !this.sessionMatches(requestGeneration, requestSession)
      ) {
        throw new ApiError(
          409,
          "session_changed",
          "Your account changed before the request completed. Try again."
        );
      }
      return undefined as T;
    }

    if (!response.ok) {
      const envelope = typeof payload === "object" && payload ? (payload as ErrorEnvelope) : {};
      throw new ApiError(
        response.status,
        envelope.error?.code || "request_failed",
        envelope.error?.detail || `Request failed with status ${response.status}`,
        envelope.error?.meta,
        retryAfterSeconds(response.headers.get("retry-after"))
      );
    }

    if (
      authenticatedRequest &&
      !this.sessionMatches(requestGeneration, requestSession)
    ) {
      throw new ApiError(
        409,
        "session_changed",
        "Your account changed before the request completed. Try again."
      );
    }

    return payload as T;
  }

  private async download(path: string, options: RequestOptions = {}): Promise<AuditExportFile> {
    const requestGeneration = this.sessionGeneration;
    const requestSession = this.session;
    const requestAccessToken = this.session?.access_token;
    const requestRefreshToken = this.session?.refresh_token;
    const headers = new Headers(options.headers);
    headers.set("Accept", "text/csv");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (requestAccessToken) {
      headers.set("Authorization", `Bearer ${requestAccessToken}`);
    }

    const response = await fetch(this.url(path), { ...options, headers });
    const shouldRetry = options.retryAuthentication !== false;
    if (
      response.status === 401 &&
      shouldRetry &&
      requestRefreshToken &&
      this.sessionMatches(requestGeneration, requestSession)
    ) {
      if (this.session?.refresh_token !== requestRefreshToken) {
        return this.download(path, {
          ...options,
          retryAuthentication: false
        });
      }
      const refreshed = await this.refresh();
      if (
        refreshed &&
        this.session?.access_token === refreshed.access_token &&
        this.session?.refresh_token === refreshed.refresh_token
      ) {
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
        envelope.error?.meta,
        retryAfterSeconds(response.headers.get("retry-after"))
      );
    }

    const blob = await response.blob();
    if (!this.sessionMatches(requestGeneration, requestSession)) {
      throw new ApiError(
        409,
        "session_changed",
        "Your account changed before the export completed. Run the export again."
      );
    }

    return {
      blob,
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
    let response: Response;
    let body: unknown;
    try {
      ({ response, body } = await fetchWithApiDeadline(
        this.url("/api/v1/sessions/refresh"),
        {
          method: "POST",
          headers: { Accept: "application/json", "Content-Type": "application/json" },
          body: JSON.stringify({ refresh_token: refreshToken }),
          signal: controller.signal
        },
        async (result) => result.ok ? result.json() : null
      ));
    } catch (error) {
      if (!this.refreshMatches(generation, refreshToken)) return null;
      throw error;
    }
    if (!this.refreshMatches(generation, refreshToken)) return null;
    if (!response.ok) {
      if ([400, 401, 403].includes(response.status)) {
        this.updateSession(null);
        return null;
      }
      throw new Error(`Session refresh is temporarily unavailable (${response.status})`);
    }
    const session = withReceivedAt(body as Session);
    this.updateSession(session);
    return session;
  }

  private updateSession(session: Session | null): void {
    this.setSession(session);
    this.onSession(session);
  }

  private sessionMatches(
    generation: number,
    session: Session | null
  ): boolean {
    return generation === this.sessionGeneration &&
      sameMemberSessionIdentity(this.session, session);
  }

  private refreshMatches(generation: number, refreshToken: string): boolean {
    return generation === this.sessionGeneration &&
      this.session?.refresh_token === refreshToken;
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }
}

function operationId(): string {
  return globalThis.crypto.randomUUID
    ? globalThis.crypto.randomUUID()
    : `web-operation-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
