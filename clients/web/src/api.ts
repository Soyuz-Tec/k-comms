import { createSharedDocumentsApi, type SharedDocumentsApi } from "./api/domains/sharedDocuments";
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
  MemberWorkspace,
  MemberWorkspaceInput,
  OnboardingAction,
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
import { createTelephonyApi } from "./api/domains/telephony";
import type { PhoneProvisioningInput, PhoneProvisioningAction } from "./features/telephony/provisioning-types";
import type { TelephonyApi } from "./api/domains/telephony";
import type { PhoneNumberInput } from "./features/telephony/types";
import { createMessagingApi } from "./api/domains/messaging";
import { createFilesApi } from "./api/domains/files";
import { createSystemApi } from "./api/domains/system";
import { createWhiteboardsApi } from "./api/domains/whiteboards";
import type { DeletionHistoryExportFile, DeletionHistoryPage, DeletionHistoryQuery } from "./types/deletionHistory";
import type { FixedRolePermission, UserRoleChangePreview } from "./types/rolePermissions";
import type { UsageExportFile, UsageQuery, UsageReport } from "./types/usage";
import type { WorkspaceDiscoveryResult, WorkspaceDomainClaim, WorkspaceDomainCreateInput, WorkspaceDomainInventory } from "./types/workspaceDiscovery";
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

import type { Meeting, MeetingInput, MeetingsQuery, UpdateMeetingInput } from "./types/meetings";
import { createMeetingsApi, type MeetingsApi } from "./api/domains/meetings";

import { createEnterpriseIdentityApi, type EnterpriseIdentityApi } from "./api/domains/enterpriseIdentity";
import { createMeetingArtifactsApi, type MeetingArtifactsApi } from "./api/domains/meeting-artifacts";

import { createRichContentApi, type RichContentApi } from "./api/domains/rich-content";
import { createVoicemailApi, type VoicemailApi } from "./api/domains/voicemail";

import { createCalendarApi, type CalendarApi } from "./api/domains/calendar";

export class ApiClient {
  private readonly transport: MemberSessionTransport;
  private readonly accountsApi: AccountsApi;
  private readonly richContentApi: RichContentApi;
  private readonly voicemailApi: VoicemailApi;
  private readonly enterpriseIdentityApi: EnterpriseIdentityApi;
  private readonly meetingArtifactsApi: MeetingArtifactsApi;
  private readonly roomsApi: RoomsApi;
  private readonly administrationApi: AdministrationApi;
  private readonly notificationsApi: NotificationsApi;
  private readonly integrationsApi: IntegrationsApi;
  private readonly callsApi: CallsApi;
  private readonly meetingsApi: MeetingsApi;
  private readonly calendarApi: CalendarApi;
  private readonly telephonyApi: TelephonyApi;
  private readonly messagingApi: MessagingApi;
  private readonly filesApi: FilesApi;
  private readonly systemApi: SystemApi;
  private readonly whiteboardsApi: WhiteboardsApi;
  readonly sharedDocuments: SharedDocumentsApi;

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
    this.richContentApi = createRichContentApi(request);
    this.voicemailApi = createVoicemailApi(request);
    const download = this.transport.download;
    this.accountsApi = createAccountsApi(request, { withReceivedAt });
    this.enterpriseIdentityApi = createEnterpriseIdentityApi(request, withReceivedAt);
    this.meetingArtifactsApi = createMeetingArtifactsApi(request);
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
    this.calendarApi = createCalendarApi(request);
    this.meetingsApi = createMeetingsApi(request);
    this.telephonyApi = createTelephonyApi(request);
    this.messagingApi = createMessagingApi(request, { resolveSenderLabelBatches });
    this.filesApi = createFilesApi(request, { attachmentContentType });
    this.systemApi = createSystemApi(request);
    this.whiteboardsApi = createWhiteboardsApi(request);
    this.sharedDocuments = createSharedDocumentsApi(request);
  }

  calendarConnections(...args: Parameters<CalendarApi["calendarConnections"]>) { return this.calendarApi.calendarConnections(...args); }
  authorizeCalendar(...args: Parameters<CalendarApi["authorizeCalendar"]>) { return this.calendarApi.authorizeCalendar(...args); }
  unlinkCalendar(...args: Parameters<CalendarApi["unlinkCalendar"]>) { return this.calendarApi.unlinkCalendar(...args); }
  calendarExports(...args: Parameters<CalendarApi["calendarExports"]>) { return this.calendarApi.calendarExports(...args); }
  createCalendarExport(...args: Parameters<CalendarApi["createCalendarExport"]>) { return this.calendarApi.createCalendarExport(...args); }
  resolveCalendarExport(...args: Parameters<CalendarApi["resolveCalendarExport"]>) { return this.calendarApi.resolveCalendarExport(...args); }

  meetings(query: MeetingsQuery): Promise<Meeting[]> { return this.meetingsApi.meetings(query); }
  createMeeting(conversationId: string, input: MeetingInput): Promise<Meeting> { return this.meetingsApi.createMeeting(conversationId, input); }
  updateMeeting(id: string, input: UpdateMeetingInput): Promise<Meeting> { return this.meetingsApi.updateMeeting(id, input); }
  getMeeting(...args: Parameters<MeetingsApi["getMeeting"]>) { return this.meetingsApi.getMeeting(...args); }
  cancelMeeting(id: string, expectedVersion: number): Promise<Meeting> { return this.meetingsApi.cancelMeeting(id, expectedVersion); }
  meetingCalendar(id: string): Promise<string> { return this.meetingsApi.meetingCalendar(id); }
  startMeeting(id: string, occurrenceId: string, mediaKind: CallMediaKind): Promise<CallSessionResponse> { return this.meetingsApi.startMeeting(id, occurrenceId, mediaKind); }

  passwordSignIn(...args: Parameters<EnterpriseIdentityApi["passwordSignIn"]>) { return this.enterpriseIdentityApi.passwordSignIn(...args); }
  completeMfaSignIn(...args: Parameters<EnterpriseIdentityApi["completeMfaSignIn"]>) { return this.enterpriseIdentityApi.completeMfaSignIn(...args); }
  startOidc(...args: Parameters<EnterpriseIdentityApi["startOidc"]>) { return this.enterpriseIdentityApi.startOidc(...args); }
  completeOidc(...args: Parameters<EnterpriseIdentityApi["completeOidc"]>) { return this.enterpriseIdentityApi.completeOidc(...args); }
  linkOidc(...args: Parameters<EnterpriseIdentityApi["linkOidc"]>) { return this.enterpriseIdentityApi.linkOidc(...args); }
  completeOidcLink(...args: Parameters<EnterpriseIdentityApi["completeOidcLink"]>) { return this.enterpriseIdentityApi.completeOidcLink(...args); }
  identitySecurity(...args: Parameters<EnterpriseIdentityApi["identitySecurity"]>) { return this.enterpriseIdentityApi.identitySecurity(...args); }
  enrollMfa(...args: Parameters<EnterpriseIdentityApi["enrollMfa"]>) { return this.enterpriseIdentityApi.enrollMfa(...args); }
  confirmMfa(...args: Parameters<EnterpriseIdentityApi["confirmMfa"]>) { return this.enterpriseIdentityApi.confirmMfa(...args); }
  disableMfa(...args: Parameters<EnterpriseIdentityApi["disableMfa"]>) { return this.enterpriseIdentityApi.disableMfa(...args); }
  rotateMfaRecovery(...args: Parameters<EnterpriseIdentityApi["rotateMfaRecovery"]>) { return this.enterpriseIdentityApi.rotateMfaRecovery(...args); }
  availability(...args: Parameters<EnterpriseIdentityApi["availability"]>) { return this.enterpriseIdentityApi.availability(...args); }
  updateAvailability(...args: Parameters<EnterpriseIdentityApi["updateAvailability"]>) { return this.enterpriseIdentityApi.updateAvailability(...args); }
  meetingArtifacts(...args: Parameters<MeetingArtifactsApi["meetingArtifacts"]>) { return this.meetingArtifactsApi.meetingArtifacts(...args); }
  requestRecording(...args: Parameters<MeetingArtifactsApi["requestRecording"]>) { return this.meetingArtifactsApi.requestRecording(...args); }
  requestTranscript(...args: Parameters<MeetingArtifactsApi["requestTranscript"]>) { return this.meetingArtifactsApi.requestTranscript(...args); }
  requestSummary(...args: Parameters<MeetingArtifactsApi["requestSummary"]>) { return this.meetingArtifactsApi.requestSummary(...args); }
  consentSummary(...args: Parameters<MeetingArtifactsApi["consentSummary"]>) { return this.meetingArtifactsApi.consentSummary(...args); }
  artifactSummary(...args: Parameters<MeetingArtifactsApi["artifactSummary"]>) { return this.meetingArtifactsApi.artifactSummary(...args); }
  consentRecording(...args: Parameters<MeetingArtifactsApi["consentRecording"]>) { return this.meetingArtifactsApi.consentRecording(...args); }
  startRecording(...args: Parameters<MeetingArtifactsApi["startRecording"]>) { return this.meetingArtifactsApi.startRecording(...args); }
  stopRecording(...args: Parameters<MeetingArtifactsApi["stopRecording"]>) { return this.meetingArtifactsApi.stopRecording(...args); }
  artifactPlayback(...args: Parameters<MeetingArtifactsApi["artifactPlayback"]>) { return this.meetingArtifactsApi.artifactPlayback(...args); }
  artifactTranscript(...args: Parameters<MeetingArtifactsApi["artifactTranscript"]>) { return this.meetingArtifactsApi.artifactTranscript(...args); }
  deleteMeetingArtifact(...args: Parameters<MeetingArtifactsApi["deleteMeetingArtifact"]>) { return this.meetingArtifactsApi.deleteMeetingArtifact(...args); }
  phoneCapabilities(...args: Parameters<TelephonyApi["phoneCapabilities"]>) { return this.telephonyApi.phoneCapabilities(...args); }
  phoneControls(...args: Parameters<TelephonyApi["phoneControls"]>) { return this.telephonyApi.phoneControls(...args); }
  requestPhoneControl(...args: Parameters<TelephonyApi["requestPhoneControl"]>) { return this.telephonyApi.requestPhoneControl(...args); }
  completePhoneControl(...args: Parameters<TelephonyApi["completePhoneControl"]>) { return this.telephonyApi.completePhoneControl(...args); }
  reconcilePhoneControl(...args: Parameters<TelephonyApi["reconcilePhoneControl"]>) { return this.telephonyApi.reconcilePhoneControl(...args); }
  phoneRoutes(...args: Parameters<TelephonyApi["phoneRoutes"]>) { return this.telephonyApi.phoneRoutes(...args); }
  savePhoneRoute(...args: Parameters<TelephonyApi["savePhoneRoute"]>) { return this.telephonyApi.savePhoneRoute(...args); }
  phoneIvrConfiguration(...args: Parameters<TelephonyApi["phoneIvrConfiguration"]>) { return this.telephonyApi.phoneIvrConfiguration(...args); }
  savePhoneIvr(...args: Parameters<TelephonyApi["savePhoneIvr"]>) { return this.telephonyApi.savePhoneIvr(...args); }
  phoneAgentState(...args: Parameters<TelephonyApi["phoneAgentState"]>) { return this.telephonyApi.phoneAgentState(...args); }
  setPhoneAgentState(...args: Parameters<TelephonyApi["setPhoneAgentState"]>) { return this.telephonyApi.setPhoneAgentState(...args); }
  phoneQueueSnapshot(...args: Parameters<TelephonyApi["phoneQueueSnapshot"]>) { return this.telephonyApi.phoneQueueSnapshot(...args); }
  voicemails(...args: Parameters<VoicemailApi["voicemails"]>) { return this.voicemailApi.voicemails(...args); }
  voicemailPlayback(...args: Parameters<VoicemailApi["voicemailPlayback"]>) { return this.voicemailApi.voicemailPlayback(...args); }
  markVoicemailRead(...args: Parameters<VoicemailApi["markVoicemailRead"]>) { return this.voicemailApi.markVoicemailRead(...args); }
  deleteVoicemail(...args: Parameters<VoicemailApi["deleteVoicemail"]>) { return this.voicemailApi.deleteVoicemail(...args); }
  voicemailMailbox(...args: Parameters<VoicemailApi["voicemailMailbox"]>) { return this.voicemailApi.voicemailMailbox(...args); }
  saveVoicemailMailbox(...args: Parameters<VoicemailApi["saveVoicemailMailbox"]>) { return this.voicemailApi.saveVoicemailMailbox(...args); }

  boardGallery(...args: Parameters<RichContentApi["boardGallery"]>) { return this.richContentApi.boardGallery(...args); }
  renameBoard(...args: Parameters<RichContentApi["renameBoard"]>) { return this.richContentApi.renameBoard(...args); }
  boardVersions(...args: Parameters<RichContentApi["boardVersions"]>) { return this.richContentApi.boardVersions(...args); }
  checkpointBoard(...args: Parameters<RichContentApi["checkpointBoard"]>) { return this.richContentApi.checkpointBoard(...args); }
  restoreBoard(...args: Parameters<RichContentApi["restoreBoard"]>) { return this.richContentApi.restoreBoard(...args); }
  exportBoard(...args: Parameters<RichContentApi["exportBoard"]>) { return this.richContentApi.exportBoard(...args); }
  addBoardAsset(...args: Parameters<RichContentApi["addBoardAsset"]>) { return this.richContentApi.addBoardAsset(...args); }
  boardAsset(...args: Parameters<RichContentApi["boardAsset"]>) { return this.richContentApi.boardAsset(...args); }
  savedItems(...args: Parameters<RichContentApi["savedItems"]>) { return this.richContentApi.savedItems(...args); }
  saveMessage(...args: Parameters<RichContentApi["saveMessage"]>) { return this.richContentApi.saveMessage(...args); }
  unsaveMessage(...args: Parameters<RichContentApi["unsaveMessage"]>) { return this.richContentApi.unsaveMessage(...args); }
  messageDraft(...args: Parameters<RichContentApi["messageDraft"]>) { return this.richContentApi.messageDraft(...args); }
  updateMessageDraft(...args: Parameters<RichContentApi["updateMessageDraft"]>) { return this.richContentApi.updateMessageDraft(...args); }
  unifiedSearch(...args: Parameters<RichContentApi["unifiedSearch"]>) { return this.richContentApi.unifiedSearch(...args); }
  stepUpOidc(...args: Parameters<EnterpriseIdentityApi["stepUpOidc"]>) { return this.enterpriseIdentityApi.stepUpOidc(...args); }

  setSession(session: Session | null): void {
    this.transport.setSession(session);
  }

  bootstrap(input: BootstrapInput): Promise<Session & { conversation: Conversation }>{
    return this.accountsApi.bootstrap(input);
  }

  login(input: LoginInput): Promise<Session>{
    return this.accountsApi.login(input);
  }

  discoverWorkspace(domain: string): Promise<WorkspaceDiscoveryResult> {
    return this.accountsApi.discoverWorkspace(domain);
  }

  workspaceDomains(): Promise<WorkspaceDomainInventory> {
    return this.administrationApi.workspaceDomains();
  }

  createWorkspaceDomain(input: WorkspaceDomainCreateInput): Promise<WorkspaceDomainClaim> {
    return this.administrationApi.createWorkspaceDomain(input);
  }

  renewWorkspaceDomain(id: string, version: number): Promise<WorkspaceDomainClaim> {
    return this.administrationApi.renewWorkspaceDomain(id, version);
  }

  verifyWorkspaceDomain(id: string, version: number): Promise<WorkspaceDomainClaim> {
    return this.administrationApi.verifyWorkspaceDomain(id, version);
  }

  updateWorkspaceDomainDiscovery(id: string, version: number, discoveryEnabled: boolean): Promise<WorkspaceDomainClaim> {
    return this.administrationApi.updateWorkspaceDomainDiscovery(id, version, discoveryEnabled);
  }

  removeWorkspaceDomain(id: string, version: number): Promise<WorkspaceDomainClaim> {
    return this.administrationApi.removeWorkspaceDomain(id, version);
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

  memberWorkspace(): Promise<MemberWorkspace> {
    return this.accountsApi.memberWorkspace();
  }

  updateMemberWorkspace(input: MemberWorkspaceInput): Promise<MemberWorkspace> {
    return this.accountsApi.updateMemberWorkspace(input);
  }

  updateOnboarding(input: { version: number; action: OnboardingAction }): Promise<MemberWorkspace> {
    return this.accountsApi.updateOnboarding(input);
  }

  updateProfile(input: Parameters<AccountsApi["updateProfile"]>[0]): Promise<User>{
    return this.accountsApi.updateProfile(input);
  }

  changePassword(input: Parameters<AccountsApi["changePassword"]>[0]): Promise<void>{
    return this.accountsApi.changePassword(input);
  }

  stepUp(currentPassword: string, mfaCode?: string): Promise<{ step_up_at: string }>{
    return this.accountsApi.stepUp(currentPassword, mfaCode);
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

  auditEventsPage(input: AuditExportInput = {}, cursor?: string) {
    return this.administrationApi.auditEventsPage(input, cursor);
  }

  exportAuditEvents(input: AuditExportInput = {}): Promise<AuditExportFile>{
    return this.administrationApi.exportAuditEvents(input);
  }

  moderationCases(input: Parameters<AdministrationApi["moderationCases"]>[0] = {}): Promise<ModerationCase[]>{
    return this.administrationApi.moderationCases(input);
  }

  moderationCase(id: string) {
    return this.administrationApi.moderationCase(id);
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

  createRetentionPolicy(input: Parameters<AdministrationApi["createRetentionPolicy"]>[0]): Promise<RetentionPolicy>{
    return this.administrationApi.createRetentionPolicy(input);
  }

  updateRetentionPolicy(id: string, input: Parameters<AdministrationApi["updateRetentionPolicy"]>[1]): Promise<RetentionPolicy>{
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

  deletionHistory(id: string, input: DeletionHistoryQuery = {}): Promise<DeletionHistoryPage> {
    return this.administrationApi.deletionHistory(id, input);
  }

  exportDeletionHistory(id: string, snapshot: string, limit = 5000): Promise<DeletionHistoryExportFile> {
    return this.administrationApi.exportDeletionHistory(id, snapshot, limit);
  }

  previewAdminUserRole(id: string, input: { role: UserRole; version: number }): Promise<UserRoleChangePreview> {
    return this.administrationApi.previewAdminUserRole(id, input);
  }

  fixedRolePermissions(): Promise<FixedRolePermission[]> {
    return this.administrationApi.fixedRolePermissions();
  }

  usageReport(input: UsageQuery = {}): Promise<UsageReport> {
    return this.administrationApi.usageReport(input);
  }

  exportUsageReport(input: UsageQuery = {}): Promise<UsageExportFile> {
    return this.administrationApi.exportUsageReport(input);
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

  inAppNotifications(limit = 50, options: { filter?: "all" | "unread"; cursor?: string | null } = {}): Promise<InAppNotificationPage>{
    return this.notificationsApi.inAppNotifications(limit, options);
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

  updateWebhook(id: string, input: { name?: string; url?: string; event_types?: string[]; status?: "active" | "disabled" }): Promise<WebhookEndpoint> {
    return this.integrationsApi.updateWebhook(id, input);
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

  phoneConfiguration() { return this.telephonyApi.phoneConfiguration(); }
  phoneAdminConfiguration() { return this.telephonyApi.phoneAdminConfiguration(); }
  phoneProvisioningState() { return this.telephonyApi.phoneProvisioningState(); }
  inspectPhoneProvisioning(input: PhoneProvisioningInput) { return this.telephonyApi.inspectPhoneProvisioning(input); }
  applyPhoneProvisioning(id: string, input: PhoneProvisioningAction) { return this.telephonyApi.applyPhoneProvisioning(id, input); }
  reconcilePhoneProvisioning(id: string, input: PhoneProvisioningAction) { return this.telephonyApi.reconcilePhoneProvisioning(id, input); }
  phoneNumberAssignment() { return this.telephonyApi.phoneNumberAssignment(); }
  updatePhoneNumber(input: PhoneNumberInput) { return this.telephonyApi.updatePhoneNumber(input); }
  phoneCalls(options: Parameters<TelephonyApi["phoneCalls"]>[0] = {}) { return this.telephonyApi.phoneCalls(options); }
  phoneCall(id: string) { return this.telephonyApi.phoneCall(id); }
  dialPhone(destination: string, idempotencyKey: string) { return this.telephonyApi.dialPhone(destination, idempotencyKey); }
  answerPhoneCall(id: string) { return this.telephonyApi.answerPhoneCall(id); }
  joinPhoneCall(id: string) { return this.telephonyApi.joinPhoneCall(id); }
  rejectPhoneCall(id: string) { return this.telephonyApi.rejectPhoneCall(id); }
  endPhoneCall(id: string) { return this.telephonyApi.endPhoneCall(id); }

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

  attachmentSafety(options: { scan_status?: NonNullable<AttachmentSafety["scan_status"]>; limit?: number } = {}): Promise<AttachmentSafety[]>{
    return this.filesApi.attachmentSafety(options);
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
