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
  MessageDeliveryCursor,
  MessagePage,
  MessageSearchOptions,
  MessageSearchPage,
  MessageThread,
  WorkspaceActivityEntry,
  CallParticipantState,
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
  WebhookEndpoint,
  WhiteboardElementData,
  WhiteboardOperation,
  WhiteboardOperationPage
} from "./types";
import {
  normalizeInstantRoomPreview,
  normalizeInstantRoomResult,
  unwrapUnknownData
} from "./api/guest/normalizers";
import { resolveSenderLabelBatches } from "./api/senderLabels";
import { withReceivedAt } from "./api/sessionIdentity";
import { MemberSessionTransport } from "./api/transport/MemberSessionTransport";
import { attachmentContentType } from "./api/uploads";
import type {
  ApiRequest,
  AuditExportInput,
  AuditExportFile,
  BootstrapInput,
  CreateConversationInput,
  CreateServiceAccountInput,
  LoginInput,
  SendMessageInput,
  UpdateTenantInput
} from "./api/contracts";
import type { AccountsApi, RoomsApi, AdministrationApi, NotificationsApi, IntegrationsApi, CallsApi, MessagingApi, FilesApi, SystemApi, WhiteboardsApi } from "./api/domain-types";
import { createAccountsApi } from "./api/domains/accounts";
import { createRoomsApi } from "./api/domains/rooms";
import { createAdministrationApi } from "./api/domains/administration";
import { createNotificationsApi } from "./api/domains/notifications";
import { createIntegrationsApi } from "./api/domains/integrations";
import { createCallsApi } from "./api/domains/calls";
import { createMessagingApi } from "./api/domains/messaging";
import { createFilesApi } from "./api/domains/files";
import { createSystemApi } from "./api/domains/system";
import { createWhiteboardsApi } from "./api/domains/whiteboards";
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

export class ApiClient {
  private readonly transport: MemberSessionTransport;
  private readonly accountsApi: AccountsApi;
  private readonly roomsApi: RoomsApi;
  private readonly administrationApi: AdministrationApi;
  private readonly notificationsApi: NotificationsApi;
  private readonly integrationsApi: IntegrationsApi;
  private readonly callsApi: CallsApi;
  private readonly messagingApi: MessagingApi;
  private readonly filesApi: FilesApi;
  private readonly systemApi: SystemApi;
  private readonly whiteboardsApi: WhiteboardsApi;

  constructor(
    baseUrl: string,
    initialSession: Session | null,
    onSession: (session: Session | null) => void
  ) {
    this.transport = new MemberSessionTransport(
      baseUrl,
      initialSession,
      onSession
    );

    const request: ApiRequest = this.transport.request;
    const download = this.transport.download;
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
    this.whiteboardsApi = createWhiteboardsApi(request);
  }

  setSession(session: Session | null): void {
    this.transport.setSession(session);
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

  callParticipants(conversationId: string, callId: string): Promise<CallParticipantState[]>{
    return this.callsApi.callParticipants(conversationId, callId);
  }

  muteCallParticipant(conversationId: string, callId: string, providerIdentity: string, trackSid: string): Promise<void>{
    return this.callsApi.muteCallParticipant(conversationId, callId, providerIdentity, trackSid);
  }

  removeCallParticipant(conversationId: string, callId: string, providerIdentity: string): Promise<void>{
    return this.callsApi.removeCallParticipant(conversationId, callId, providerIdentity);
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

  deliveryCursors(conversationId: string): Promise<MessageDeliveryCursor[]>{
    return this.messagingApi.deliveryCursors(conversationId);
  }

  markDelivered(conversationId: string, sequence: number): Promise<MessageDeliveryCursor>{
    return this.messagingApi.markDelivered(conversationId, sequence);
  }

  conversationActivity(conversationId: string, limit = 50): Promise<WorkspaceActivityEntry[]>{
    return this.messagingApi.conversationActivity(conversationId, limit);
  }

  whiteboardOperations(
    conversationId: string,
    afterSequence = 0,
    limit = 500
  ): Promise<WhiteboardOperationPage>{
    return this.whiteboardsApi.operations(conversationId, afterSequence, limit);
  }

  appendWhiteboardSceneUpdate(
    conversationId: string,
    clientOperationId: string,
    baseSequence: number,
    elements: WhiteboardElementData[]
  ): Promise<WhiteboardOperation>{
    return this.whiteboardsApi.appendSceneUpdate(
      conversationId,
      clientOperationId,
      baseSequence,
      elements
    );
  }

  clearWhiteboard(
    conversationId: string,
    clientOperationId: string
  ): Promise<WhiteboardOperation>{
    return this.whiteboardsApi.clearWhiteboard(conversationId, clientOperationId);
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

  logout(): Promise<void> {
    return this.transport.logout();
  }

  refreshSession(): Promise<Session | null> {
    return this.transport.refreshSession();
  }
}

function operationId(): string {
  return globalThis.crypto.randomUUID
    ? globalThis.crypto.randomUUID()
    : `web-operation-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
