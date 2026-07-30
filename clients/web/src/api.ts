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
  GuestAccountConversionResult,
  GuestLinkPreview,
  GuestSession,
  InstantRoom,
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
  UploadDescriptor,
  UserRole,
  User,
  WebhookDelivery,
  WebhookEndpoint
} from "./types";
import { sha256BlobHex } from "./lib/sha256";
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


const sessionKey = "k-comms.session.v1";
const guestSessionKey = "k-comms.guest-session.v1";
const senderLabelBatchSize = 200;
const apiRequestDeadlineMs = 30_000;

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly meta?: unknown;
  readonly retryAfterSeconds?: number;

  constructor(
    status: number,
    code: string,
    message: string,
    meta?: unknown,
    retryAfterSeconds?: number
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.meta = meta;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

function sameMemberSessionIdentity(
  left: Session | null,
  right: Session | null
): boolean {
  if (!left || !right) return left === right;
  return left.tenant.id === right.tenant.id &&
    left.user.id === right.user.id &&
    left.device.id === right.device.id;
}

function sameGuestSessionIdentity(
  left: GuestSession | null,
  right: GuestSession | null
): boolean {
  if (!left || !right) return left === right;
  return left.tenant.id === right.tenant.id &&
    left.user.id === right.user.id &&
    left.device.id === right.device.id &&
    left.conversation.id === right.conversation.id;
}

interface DeadlineResponse<T> {
  response: Response;
  body: T;
}

async function fetchWithApiDeadline<T>(
  input: RequestInfo | URL,
  init: RequestInit,
  readBody: (response: Response) => Promise<T>
): Promise<DeadlineResponse<T>> {
  const callerSignal = init.signal;
  const controller = new AbortController();
  let abortSource: "caller" | "deadline" | null = null;
  const timeoutError = new ApiError(
    408,
    "request_timeout",
    "K-Comms did not respond in time. Try again."
  );

  const abortFromCaller = () => {
    if (abortSource) return;
    abortSource = "caller";
    controller.abort(callerSignal?.reason);
  };

  if (callerSignal?.aborted) {
    abortFromCaller();
  } else {
    callerSignal?.addEventListener("abort", abortFromCaller, { once: true });
  }

  const timeout = globalThis.setTimeout(() => {
    if (abortSource) return;
    abortSource = "deadline";
    controller.abort(timeoutError);
  }, apiRequestDeadlineMs);

  try {
    const response = await fetch(input, { ...init, signal: controller.signal });
    return { response, body: await readBody(response) };
  } catch (error) {
    if (abortSource === "deadline") throw timeoutError;
    throw error;
  } finally {
    globalThis.clearTimeout(timeout);
    callerSignal?.removeEventListener("abort", abortFromCaller);
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

export class GuestApiClient {
  private session: GuestSession | null;
  private refreshPromise: Promise<GuestSession | null> | null = null;
  private refreshController: AbortController | null = null;
  private sessionGeneration = 0;

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
    const credentialsChanged =
      this.session?.access_token !== session?.access_token ||
      this.session?.refresh_token !== session?.refresh_token;
    if (!sameGuestSessionIdentity(this.session, session)) {
      this.sessionGeneration += 1;
    }
    if (credentialsChanged) {
      this.refreshController?.abort();
    }
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

  joinInstantRoom(input: {
    token: string;
    display_name?: string;
    device?: { name: string; platform: "web" };
  }, idempotencyKey: string): Promise<GuestSession> {
    return this.request<unknown>("/api/v1/instant-room-sessions", {
      method: "POST",
      headers: { "Idempotency-Key": idempotencyKey },
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then((payload) => {
      const result = normalizeInstantRoomResult(payload);
      if (!result.guest_session) {
        throw new Error("The server did not return a guest room session.");
      }
      this.updateSession(result.guest_session);
      return result.guest_session;
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
      limit: String(limit),
      include: "sender_labels"
    });
    return this.request(`/api/v1/guest/conversation/messages?${query.toString()}`);
  }

  messageSenderLabels(messageIds: string[]): Promise<RetainedSenderLabel[]> {
    return resolveSenderLabelBatches(messageIds, (batch) =>
      this.request<DataResponse<RetainedSenderLabel[]>>(
        "/api/v1/guest/conversation/message-sender-labels",
        {
          method: "POST",
          body: JSON.stringify({ message_ids: batch })
        }
      ).then((response) => response.data)
    );
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
    password: string;
    verification_code?: string;
    display_name?: string;
  }): Promise<GuestAccountConversionResult> {
    return this.request<unknown>("/api/v1/guest/account", {
      method: "POST",
      body: JSON.stringify(input)
    }).then(normalizeAccountConversion);
  }

  async logout(): Promise<void> {
    const revocation = this.session
      ? this.request("/api/v1/guest/sessions/current", {
        method: "DELETE",
        keepalive: true,
        retryAuthentication: false
      }).catch(() => undefined)
      : Promise.resolve();
    this.updateSession(null, "logout");
    await revocation;
  }

  private async request<T = void>(path: string, options: RequestOptions = {}): Promise<T> {
    const requestGeneration = this.sessionGeneration;
    const requestSession = this.session;
    const requestAccessToken = this.session?.access_token;
    const requestRefreshToken = this.session?.refresh_token;
    const authenticatedRequest = Boolean(requestAccessToken);
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (requestAccessToken) {
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
          "Your guest visit changed before the request completed. Try again."
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
        "Your guest visit changed before the request completed. Try again."
      );
    }
    return payload as T;
  }

  private refresh(): Promise<GuestSession | null> {
    if (!this.refreshPromise) {
      this.refreshPromise = this.performRefresh().finally(() => {
        this.refreshPromise = null;
        this.refreshController = null;
      });
    }
    return this.refreshPromise;
  }

  private async performRefresh(): Promise<GuestSession | null> {
    const refreshToken = this.session?.refresh_token;
    if (!refreshToken) return null;
    const generation = this.sessionGeneration;
    const controller = new AbortController();
    this.refreshController = controller;
    let response: Response;
    let payload: unknown;
    try {
      ({ response, body: payload } = await fetchWithApiDeadline(
        this.url("/api/v1/guest/sessions/refresh"),
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
        this.updateSession(null, "access_ended");
        return null;
      }
      throw new Error(`Guest session refresh is temporarily unavailable (${response.status})`);
    }

    const previous = this.session;
    if (!previous) return null;
    const refreshed = normalizeGuestSession({
      ...(readObject(payload) || {}),
      conversation: readObject(payload)?.conversation || previous.conversation,
      capabilities: readObject(payload)?.capabilities || previous.capabilities,
      admission: readObject(payload)?.admission || previous.admission,
      room:
        readObject(payload)?.room ||
        readObject(payload)?.instant_room ||
        previous.instant_room,
      share_url: firstString(
        readObject(payload)?.share_url,
        previous.share_url
      )
    });
    this.updateSession(refreshed);
    return refreshed;
  }

  private updateSession(
    session: GuestSession | null,
    reason?: "access_ended" | "logout"
  ): void {
    this.setSession(session);
    if (reason) {
      this.onSession(session, reason);
    } else {
      this.onSession(session);
    }
  }

  private sessionMatches(
    generation: number,
    session: GuestSession | null
  ): boolean {
    return generation === this.sessionGeneration &&
      sameGuestSessionIdentity(this.session, session);
  }

  private refreshMatches(generation: number, refreshToken: string): boolean {
    return generation === this.sessionGeneration &&
      this.session?.refresh_token === refreshToken;
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }
}

async function resolveSenderLabelBatches(
  messageIds: string[],
  resolveBatch: (messageIds: string[]) => Promise<RetainedSenderLabel[]>
): Promise<RetainedSenderLabel[]> {
  const normalizedIds = [...new Set(messageIds)].sort();
  const labels: RetainedSenderLabel[] = [];

  for (let offset = 0; offset < normalizedIds.length; offset += senderLabelBatchSize) {
    labels.push(
      ...await resolveBatch(
        normalizedIds.slice(offset, offset + senderLabelBatchSize)
      )
    );
  }

  return labels;
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
  const outer = readObject(payload);
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
      self_service_conversion: capabilities.self_service_conversion === true,
      email_hint:
        typeof capabilities.email_hint === "string"
          ? capabilities.email_hint
          : null
    },
    admission: readObject(root?.admission) as unknown as GuestSession["admission"],
    instant_room: normalizeInstantRoom(
      root?.room || root?.instant_room || outer?.room || outer?.instant_room,
      conversation
    ) || undefined,
    share_url: firstString(
      root?.share_url,
      outer?.share_url,
      readObject(outer?.data)?.share_url
    )
  });
}

function normalizeInstantRoomResult(payload: unknown): InstantRoomResult {
  const outer = readObject(payload);
  const data = readObject(outer?.data);
  const root = data || outer;
  const authentication =
    readObject(root?.authentication) ||
    readObject(root?.auth) ||
    readObject(root?.session) ||
    root;
  const conversation =
    readObject(root?.conversation) ||
    readObject(authentication?.conversation) ||
    readObject(outer?.conversation);
  if (!conversation || typeof conversation.id !== "string") {
    throw new Error("The server did not return the instant-room conversation.");
  }

  const room = normalizeInstantRoom(
    root?.room || root?.instant_room || outer?.room || outer?.instant_room,
    conversation
  );
  if (!room) {
    throw new Error("The server did not return complete instant-room details.");
  }

  const shareUrl = firstString(root?.share_url, outer?.share_url);
  let guestSession: GuestSession | undefined;
  if (typeof authentication?.access_token === "string") {
    guestSession = normalizeGuestSession({
      ...outer,
      ...root,
      room,
      conversation,
      share_url: shareUrl
    });
  }

  return {
    room,
    conversation: conversation as unknown as Conversation,
    share_url: shareUrl,
    guest_session: guestSession
  };
}

function normalizeInstantRoom(
  value: unknown,
  conversation?: Record<string, unknown> | null
): InstantRoom | null {
  const room = readObject(value);
  const id = firstString(room?.id);
  const conversationId = firstString(room?.conversation_id, conversation?.id);
  const ownerUserId = firstString(room?.owner_user_id);
  const participantLimit = nonNegativeSafeInteger(room?.participant_limit);
  const insertedAt = firstString(room?.inserted_at);
  const updatedAt = firstString(room?.updated_at);
  if (
    !id ||
    !conversationId ||
    !ownerUserId ||
    participantLimit === undefined ||
    !insertedAt ||
    !updatedAt
  ) {
    return null;
  }

  const ownerKind =
    room?.owner_kind === "registered" ? "registered" : "guest";
  const rawStatus = firstString(room?.status);
  const status =
    rawStatus === "idle" ||
    rawStatus === "expired" ||
    rawStatus === "revoked"
      ? rawStatus
      : "active";
  return {
    id,
    conversation_id: conversationId,
    owner_user_id: ownerUserId,
    owner_kind: ownerKind,
    status,
    participant_limit: participantLimit,
    idle_since: firstString(room?.idle_since) || null,
    expires_at: firstString(room?.expires_at) || null,
    inserted_at: insertedAt,
    updated_at: updatedAt
  };
}

function normalizeInstantRoomPreview(value: unknown): InstantRoomPreview {
  const preview = readObject(value);
  const roomTitle = firstString(preview?.room_title);
  const participantLimit = nonNegativeSafeInteger(preview?.participant_limit);
  const rawStatus = firstString(preview?.status);
  if (
    !roomTitle ||
    participantLimit === undefined ||
    !["active", "idle", "expired", "revoked"].includes(rawStatus || "")
  ) {
    throw new Error("The server did not return a complete instant-room preview.");
  }
  return {
    room_title: roomTitle,
    status: rawStatus as InstantRoomPreview["status"],
    expires_at: firstString(preview?.expires_at) || null,
    participant_limit: participantLimit
  };
}

function normalizeAccountConversion(payload: unknown): {
  session: Session;
  conversation: Conversation;
  socket_handoff?: { ticket: string; expires_in: number };
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
  const handoff = readObject(root?.socket_handoff);
  const socketHandoff =
    typeof handoff?.ticket === "string" &&
    typeof handoff.expires_in === "number" &&
    Number.isSafeInteger(handoff.expires_in) &&
    handoff.expires_in > 0
      ? {
          ticket: handoff.ticket,
          expires_in: handoff.expires_in
        }
      : undefined;
  return {
    session: withReceivedAt(authentication as unknown as Session),
    conversation: conversation as unknown as Conversation,
    socket_handoff: socketHandoff
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

function firstString(...values: unknown[]): string | undefined {
  return values.find(
    (value): value is string => typeof value === "string" && value.length > 0
  );
}

function nonNegativeSafeInteger(value: unknown): number | undefined {
  return typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= 0
    ? value
    : undefined;
}

function retryAfterSeconds(value: string | null): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.ceil(seconds);

  const deadline = Date.parse(value);
  if (!Number.isFinite(deadline)) return undefined;
  return Math.max(0, Math.ceil((deadline - Date.now()) / 1_000));
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
  return sha256BlobHex(file);
}

/** Hashes a generated Blob, which unlike an upload is not a File. */
export async function sha256Blob(blob: Blob): Promise<string> {
  return sha256BlobHex(blob);
}

/**
 * Uploads through XMLHttpRequest rather than fetch because fetch reports no
 * progress for a request body: the browser exposes upload progress only through
 * XHR's upload events. Without them the queue can show that an upload is
 * running but never how far along it is, which is indistinguishable from a
 * stall on a large file over a slow link.
 */
export async function uploadToPresignedTarget(
  descriptor: UploadDescriptor,
  file: File | Blob,
  signal?: AbortSignal,
  onProgress?: (fraction: number) => void
): Promise<void> {
  const url = validatedPresignedUrl(descriptor);

  let body: XMLHttpRequestBodyInit = file;
  const headers = new Headers(descriptor.headers);
  if (descriptor.fields && Object.keys(descriptor.fields).length > 0) {
    const form = new FormData();
    Object.entries(descriptor.fields).forEach(([key, value]) => form.append(key, value));
    form.append("file", file);
    body = form;
  } else if (!headers.has("content-type")) {
    headers.set("content-type", attachmentContentType(file));
  }

  const method = descriptor.method || (descriptor.fields ? "POST" : "PUT");

  await new Promise<void>((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError());
      return;
    }

    const request = new XMLHttpRequest();
    request.open(method, url, true);
    headers.forEach((value, name) => request.setRequestHeader(name, value));

    const detach = () => signal?.removeEventListener("abort", onAbort);
    const onAbort = () => request.abort();
    signal?.addEventListener("abort", onAbort, { once: true });

    request.upload.addEventListener("progress", (event) => {
      // Without a total the browser cannot report a fraction, so the caller
      // keeps its indeterminate state rather than being fed a fabricated one.
      if (!onProgress || !event.lengthComputable || event.total <= 0) return;
      onProgress(Math.min(1, event.loaded / event.total));
    });

    request.addEventListener("load", () => {
      detach();
      if (request.status >= 200 && request.status < 300) {
        onProgress?.(1);
        resolve();
        return;
      }
      reject(new Error(`Object upload failed with status ${request.status}`));
    });

    request.addEventListener("error", () => {
      detach();
      reject(new Error("Object upload failed"));
    });

    request.addEventListener("abort", () => {
      detach();
      reject(abortError());
    });

    request.send(body);
  });
}

/**
 * Mirrors the DOMException fetch raises on abort so existing callers, which
 * detect cancellation by name, keep working unchanged.
 */
function abortError(): Error {
  if (typeof DOMException === "function") return new DOMException("Aborted", "AbortError");
  const error = new Error("Aborted");
  error.name = "AbortError";
  return error;
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
  const privateLanEvaluation = isApprovedPrivateLanObjectUrl(
    target,
    approved,
    new URL(window.location.href)
  );
  if (target.protocol !== "https:" && !localDevelopment && !privateLanEvaluation) {
    throw new Error("Object-store URLs must use HTTPS");
  }
  return target.toString();
}

export function isApprovedPrivateLanObjectUrl(
  target: URL,
  approved: URL,
  page: URL
): boolean {
  return (
    target.protocol === "http:" &&
    approved.protocol === "http:" &&
    page.protocol === "http:" &&
    target.origin === approved.origin &&
    target.hostname === approved.hostname &&
    target.hostname === page.hostname &&
    isCanonicalRfc1918Host(target.hostname)
  );
}

function isCanonicalRfc1918Host(hostname: string): boolean {
  const parts = hostname.split(".");
  if (parts.length !== 4) return false;
  if (parts.some((part) => !/^(0|[1-9][0-9]{0,2})$/.test(part))) return false;
  const octets = parts.map(Number);
  if (octets.some((octet) => octet > 255)) return false;
  const [first, second] = octets as [number, number, number, number];
  return (
    first === 10 ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168)
  );
}

function attachmentContentType(file: File | Blob): string {
  if (file.type) return file.type;
  // A generated Blob carries no name to infer from, and its descriptor already
  // signs an explicit content type, so extension sniffing is File-only.
  if (!(file instanceof File)) return "application/octet-stream";
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
