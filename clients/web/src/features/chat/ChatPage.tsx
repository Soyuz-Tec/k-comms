import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties
} from "react";
import { useSearchParams } from "react-router";
import type { CreateConversationInput } from "../../api";
import { useSession } from "../../app/session";
import { useStepUp } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { ActionDialog } from "../../components/ActionDialog";
import { AppIcon } from "../../components/AppIcon";
import { useCallSession } from "../calls/CallSessionProvider";
import { callAvailabilityGuidance } from "../calls/callAvailability";
import { conversationTitle, errorText } from "../../lib/format";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  participantIdentifier,
  resolveVisibleSenderIdentity,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import { canManageUsers } from "../../lib/roles";
import type { Message, MessageMetadata, WhiteboardMessageReference } from "../../types";
import { ConversationDetails } from "./ConversationDetails";
import {
  ConversationSidebar,
  type InboxFilter
} from "./ConversationSidebar";
import { ChannelBrowser } from "./ChannelBrowser";
import { SearchPanel } from "./SearchPanel";
import { ThreadDrawer } from "./ThreadDrawer";
import { ConversationShareDialog } from "../guest/ConversationShareDialog";
import {
  readOnboardingPreference,
  safeCallKind,
  safePositiveInteger,
  safeUuid
} from "./chatSupport";
import { ConversationPane } from "./ConversationPane";
import {
  ConversationColumnResizer,
  persistConversationSidebarWidth,
  readConversationSidebarWidth
} from "./ConversationColumnResizer";
import { ConversationActivityTimeline } from "./ConversationActivityTimeline";
import { useChatAttachments } from "./useChatAttachments";
import { useChatComposer } from "./useChatComposer";
import { useChatNavigation } from "./useChatNavigation";
import {
  clearCallReadinessSearch,
  safeCallReadinessMode
} from "../calls/callReadinessNavigation";
import { useActiveConversationCalls } from "./useActiveConversationCalls";
import { useConversationFeed } from "./useConversationFeed";
import { useConversationMembers } from "./useConversationMembers";
import "./ChatPage.css";

interface FocusTarget {
  id: string;
  conversationId: string;
  sequence: number;
}

export function ChatPage() {
  const { api, session } = useSession();
  const [conversationSidebarWidth, setConversationSidebarWidth] = useState(
    readConversationSidebarWidth
  );
  useEffect(() => {
    persistConversationSidebarWidth(conversationSidebarWidth);
  }, [conversationSidebarWidth]);
  const { runWithStepUp } = useStepUp();
  const {
    launchCall,
    publishRealtimeEvent,
    sessionState: callSessionState,
    targetConversation: callTargetConversation
  } = useCallSession();
  const {
    conversations,
    users,
    capabilities,
    audioCallsAvailable,
    videoCallsAvailable,
    loading: workspaceLoading,
    setError,
    setConversations,
    createConversation,
    startDirectConversation,
    refreshConversations
  } = useWorkspaceData();
  const onboardingStorageKey = session ? `k-comms:onboarding:${session.tenant.id}:${session.user.id}` : "k-comms:onboarding:anonymous";
  const [searchParams, setSearchParams] = useSearchParams();
  const activeConversationId = searchParams.get("conversation");
  const linkedMessageId = safeUuid(searchParams.get("message"));
  const linkedSearchMessageId = safeUuid(searchParams.get("search_message"));
  const linkedSearchSequence = safePositiveInteger(searchParams.get("search_sequence"));
  const linkedCallKind = safeCallKind(searchParams.get("call"));
  const linkedCallReadinessMode = safeCallReadinessMode(
    searchParams.get("call_readiness")
  );
  const whiteboardReference = useMemo(
    () => readWhiteboardReference(searchParams),
    [searchParams]
  );
  const clearWhiteboardReference = useCallback(() => {
    const next = new URLSearchParams(searchParams);
    next.delete("whiteboard_elements");
    next.delete("whiteboard_sequence");
    next.delete("whiteboard_label");
    setSearchParams(next, { replace: true });
  }, [searchParams, setSearchParams]);
  const [threadTargetId, setThreadTargetId] = useState<string | null>(null);
  const [showCreateConversation, setShowCreateConversation] = useState(false);
  const [showSearch, setShowSearch] = useState(false);
  const [showDetails, setShowDetails] = useState(false);
  const [showActivity, setShowActivity] = useState(false);
  const [showGuestShare, setShowGuestShare] = useState(false);
  const [showBrowseChannels, setShowBrowseChannels] = useState(false);
  const [focusTarget, setFocusTarget] = useState<FocusTarget | null>(null);
  const [membershipVersion, setMembershipVersion] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const [reportTarget, setReportTarget] = useState<Message | null>(null);
  const [reporting, setReporting] = useState(false);
  const [reportError, setReportError] = useState<string | null>(null);
  const [conversationQuery, setConversationQuery] = useState("");
  const [inboxFilter, setInboxFilter] = useState<InboxFilter>("all");
  const [showOnboarding, setShowOnboarding] = useState(() => session ? readOnboardingPreference(onboardingStorageKey) : false);
  const [directStartingUserId, setDirectStartingUserId] = useState<string | null>(null);
  const activeCallConversationIds = useActiveConversationCalls(api);
  const forceScrollToLatestRef = useRef(true);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const directStartUserRef = useRef<string | null>(null);
  const activeConversation = useMemo(
    () => conversations.find(({ id }) => id === activeConversationId) || null,
    [activeConversationId, conversations]
  );
  const closeConversationPanels = useCallback(() => {
    setShowDetails(false);
    setShowBrowseChannels(false);
    setShowGuestShare(false);
    setShowActivity(false);
  }, []);
  const {
    conversationButtonRefs,
    focusComposerAfterDirect,
    isMobile,
    mobileBackRef,
    mobilePane,
    selectConversation,
    showConversationList
  } = useChatNavigation({
    activeConversation,
    activeConversationId,
    conversations,
    setSearchParams,
    workspaceLoading,
    closeConversationPanels
  });
  const {
    pendingAttachments,
    uploading,
    ready: attachmentsReady,
    readyAttachmentIds,
    filesSelected,
    cancelAttachment,
    retryAttachment,
    reset: resetAttachments,
    clearPending: clearPendingAttachments,
    reserveForSend: reserveAttachmentsForSend,
    openAttachment,
    requestThumbnail: requestAttachmentThumbnail
  } = useChatAttachments({ api, capabilities, setError });
  const {
    members: conversationMembers,
    memberUsersById: conversationMemberUsersById,
    retainedSenderLabels: retainedSenderLabelsById,
    mergeRetainedSenderLabels,
    scheduleRefresh: scheduleConversationMembersRefresh,
    notePresence: noteConversationPresence,
    noteRealtimeDisconnected: noteConversationRealtimeDisconnected,
    trackVisibleMessages
  } = useConversationMembers({
    api,
    activeConversationId,
    setError
  });
  const noteMembershipChanged = useCallback(
    () => setMembershipVersion((value) => value + 1),
    []
  );
  const {
    messages,
    messagesLoading,
    olderLoading,
    hasOlder,
    connectionStatus,
    onlineUsers,
    typingUsers,
    readCursors,
    deliveryCursors,
    isNearBottom,
    newMessageCount,
    latestSequence,
    updateNearBottom,
    shouldAutoScroll,
    receiveMessages,
    updateConversationSummaries,
    applyReaction,
    loadOlder,
    sendCommand,
    setTyping: setConversationTyping
  } = useConversationFeed({
    api,
    session,
    activeConversation,
    activeConversationId,
    linkedSearchSequence,
    readerActive: !isMobile || mobilePane === "messages",
    setError,
    setConversations,
    refreshConversations,
    mergeRetainedSenderLabels,
    scheduleMemberRefresh: scheduleConversationMembersRefresh,
    notePresence: noteConversationPresence,
    noteRealtimeDisconnected: noteConversationRealtimeDisconnected,
    onMembershipChanged: noteMembershipChanged,
    publishRealtimeEvent
  });
  const onConversationChanged = useCallback(
    () => setThreadTargetId(null),
    []
  );
  const {
    activeConversationIdRef,
    composer,
    composerChanged,
    failedSend,
    mentionedUserIds,
    replyTo,
    retrySend,
    sendMessage,
    sendThreadReply,
    sending,
    setMentionedUserIds,
    setReplyTo
  } = useChatComposer({
    activeConversationId,
    attachmentsReady,
    clearPendingAttachments,
    forceScrollToLatestRef,
    onConversationChanged,
    messageMetadata: whiteboardReference
      ? ({ whiteboard_reference: whiteboardReference } satisfies MessageMetadata)
      : undefined,
    onMetadataSent: clearWhiteboardReference,
    readyAttachmentIds,
    receiveMessages,
    reserveAttachmentsForSend,
    resetAttachments,
    sendCommand,
    session,
    setConversationTyping,
    setError,
    updateConversationSummaries
  });

  useEffect(() => {
    trackVisibleMessages(messages);
  }, [messages, trackVisibleMessages]);

  const filteredConversations = useMemo(() => {
    const query = conversationQuery.trim().toLocaleLowerCase();
    return conversations.filter((conversation) => {
      if (inboxFilter === "unread" && (conversation.unread_count || 0) === 0) return false;
      if (inboxFilter === "direct" && conversation.kind !== "direct") return false;
      if (inboxFilter === "rooms" && !["group", "channel"].includes(conversation.kind)) return false;
      if (query && !conversationTitle(conversation).toLocaleLowerCase().includes(query)) return false;
      return true;
    });
  }, [conversationQuery, conversations, inboxFilter]);
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const activeConversationMemberUsersById = useMemo(
    () => new Map(conversationMembers.map(({ user }) => [user.id, user])),
    [conversationMembers]
  );
  const visibleSenderIdentities = useMemo(() => {
    const identitiesById = new Map<string, ParticipantIdentity>();
    for (const message of messages) {
      const identity = resolveVisibleSenderIdentity(
        message.sender_user_id,
        activeConversationMemberUsersById,
        retainedSenderLabelsById,
        [conversationMemberUsersById, usersById]
      );
      if (identity) identitiesById.set(identity.id, identity);
    }
    return identitiesById;
  }, [
    activeConversationMemberUsersById,
    conversationMemberUsersById,
    messages,
    retainedSenderLabelsById,
    usersById
  ]);
  const duplicateVisibleSenderNames = useMemo(
    () => duplicateParticipantNames(visibleSenderIdentities.values()),
    [visibleSenderIdentities]
  );
  const visibleSenderIdentifier = useCallback(
    (userId: string): string | undefined => {
      const identity = visibleSenderIdentities.get(userId);
      return identity
        ? participantIdentifier(identity, duplicateVisibleSenderNames)
        : undefined;
    },
    [duplicateVisibleSenderNames, visibleSenderIdentities]
  );
  useEffect(() => {
    if (!linkedCallKind || !activeConversation) return;
    if (linkedCallReadinessMode) {
      launchCall(activeConversation, linkedCallKind, linkedCallReadinessMode);
    } else {
      launchCall(activeConversation, linkedCallKind);
    }
    const next = clearCallReadinessSearch(searchParams);
    setSearchParams(next, { replace: true });
  }, [
    activeConversation,
    launchCall,
    linkedCallKind,
    linkedCallReadinessMode,
    searchParams,
    setSearchParams
  ]);

  useEffect(() => {
    if (activeConversationId && linkedMessageId) setThreadTargetId(linkedMessageId);
  }, [activeConversationId, linkedMessageId]);

  useEffect(() => {
    if (activeConversationId && linkedSearchMessageId && linkedSearchSequence) {
      setFocusTarget({
        id: linkedSearchMessageId,
        conversationId: activeConversationId,
        sequence: linkedSearchSequence
      });
    }
  }, [activeConversationId, linkedSearchMessageId, linkedSearchSequence]);

  useEffect(() => {
    if (!focusTarget || focusTarget.conversationId !== activeConversationId) return;
    const element = document.getElementById(`message-${focusTarget.id}`);
    if (element) {
      element.scrollIntoView({ behavior: "smooth", block: "center" });
      const timer = window.setTimeout(() => setFocusTarget(null), 3_000);
      return () => window.clearTimeout(timer);
    }
  }, [activeConversationId, focusTarget, messages.length]);

  useEffect(() => {
    if (focusTarget?.conversationId === activeConversationId) return;
    if (!shouldAutoScroll() && !forceScrollToLatestRef.current) return;
    messagesEndRef.current?.scrollIntoView({ behavior: forceScrollToLatestRef.current ? "smooth" : "auto", block: "nearest" });
    forceScrollToLatestRef.current = false;
    updateNearBottom(true);
  }, [
    activeConversationId,
    focusTarget?.conversationId,
    latestSequence,
    shouldAutoScroll,
    updateNearBottom
  ]);

  function messageScrollChanged() {
    const scroll = scrollRef.current;
    if (!scroll) return;
    updateNearBottom(scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight <= 96);
  }

  function jumpToLatest() {
    forceScrollToLatestRef.current = false;
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
    updateNearBottom(true);
  }

  async function create(input: CreateConversationInput) {
    setError(null);
    try {
      const conversation = await createConversation(input);
      setShowCreateConversation(false);
      selectConversation(conversation.id);
    } catch (reason: unknown) {
      setError(errorText(reason));
    }
  }

  async function startDirect(userId: string) {
    if (directStartUserRef.current) return;
    directStartUserRef.current = userId;
    setDirectStartingUserId(userId);
    setError(null);
    try {
      const conversation = await startDirectConversation(userId);
      setShowCreateConversation(false);
      focusComposerAfterDirect();
      selectConversation(conversation.id);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      directStartUserRef.current = null;
      setDirectStartingUserId(null);
    }
  }

  async function toggleReaction(message: Message, emoji: string) {
    if (!session || !activeConversationId) return;
    const conversationId = activeConversationId;
    const exists = message.reactions.some((reaction) => reaction.user_id === session.user.id && reaction.emoji === emoji);
    const event = { message_id: message.id, emoji, user_id: session.user.id };
    applyReaction(event, !exists);
    try {
      if (exists) await api.removeReaction(conversationId, message.id, emoji); else await api.addReaction(conversationId, message.id, emoji);
    } catch (reason: unknown) {
      if (activeConversationIdRef.current === conversationId) {
        applyReaction(event, exists);
        setError(errorText(reason));
      }
    }
  }

  async function editMessage(message: Message, body: string) {
    const conversationId = message.conversation_id;
    try {
      const updated = await api.editMessage(message.id, body);
      if (activeConversationIdRef.current === conversationId) {
        receiveMessages([updated]);
      } else {
        updateConversationSummaries([updated]);
      }
    } catch (reason: unknown) {
      if (activeConversationIdRef.current === conversationId) {
        setError(errorText(reason));
      }
      throw reason;
    }
  }

  async function deleteMessage(message: Message) {
    const conversationId = message.conversation_id;
    try {
      const deleted = await api.deleteMessage(message.id);
      if (activeConversationIdRef.current === conversationId) {
        receiveMessages([deleted]);
      } else {
        updateConversationSummaries([deleted]);
      }
    } catch (reason: unknown) {
      if (activeConversationIdRef.current === conversationId) {
        setError(errorText(reason));
      }
      throw reason;
    }
  }

  async function submitReport(details: string) {
    if (!reportTarget) return;
    setReporting(true);
    setReportError(null);
    setError(null);
    try {
      await api.createModerationCase({
        message_id: reportTarget.id,
        conversation_id: reportTarget.conversation_id,
        category: "message_content",
        summary: details.trim().slice(0, 160),
        details: details.trim(),
        priority: "normal"
      });
      setNotice("Report submitted to workspace moderators.");
      setReportTarget(null);
    } catch (reason: unknown) {
      const message = errorText(reason);
      setReportError(message);
      setError(message);
    } finally {
      setReporting(false);
    }
  }

  if (!session) return null;
  if (workspaceLoading) return <main className="centered-page" id="main-content" aria-busy="true"><div className="loading-card"><span className="spinner" aria-hidden="true" /><p>Opening your workspace…</p></div></main>;

  const activeTypingIdentities = [...typingUsers]
    .filter((id) => id !== session.user.id)
    .map((id) => {
      const identity = conversationMemberUsersById.get(id) || usersById.get(id);
      return identity
        ? { id, display_name: identity.display_name }
        : { id, display_name: "Someone" };
    });
  const duplicateTypingNames = duplicateParticipantNames(activeTypingIdentities);
  const activeTyping = activeTypingIdentities.map((identity) =>
    participantIdentifier(identity, duplicateTypingNames)
  );
  const otherHumanAccounts = users.filter(
    (user) => user.id !== session.user.id && user.account_type !== "service"
  );
  const conversationUsers = users.filter((user) => user.id !== session.user.id && user.status === "active");
  const humanTeammates = conversationUsers.filter(
    ({ account_type: accountType }) => accountType !== "service"
  );
  const duplicateTeammateNames = duplicateParticipantNames(humanTeammates);
  const duplicateDirectCounterpartNames =
    duplicateDirectConversationNames(conversations);
  const conversationIdentifier = (conversation: (typeof conversations)[number]) =>
    conversationParticipantIdentifier(
      conversation,
      duplicateDirectCounterpartNames
    );
  const inactiveHumanTeammates = otherHumanAccounts.filter(({ status }) => status !== "active");
  const canInviteTeammates = canManageUsers(session.user.role);
  const needsFirstTeammate =
    canInviteTeammates &&
    otherHumanAccounts.length === 0;
  const needsTeammateAccessReview =
    canInviteTeammates &&
    humanTeammates.length === 0 &&
    inactiveHumanTeammates.length > 0;
  const showOnboardingSpotlight =
    showOnboarding &&
    (needsFirstTeammate || needsTeammateAccessReview || conversations.length === 0);
  const callGuidance = capabilities
    ? callAvailabilityGuidance({
        allowAudio: capabilities.allow_audio_calls === true,
        allowVideo: capabilities.allow_video_calls === true,
        audioAvailable: audioCallsAvailable,
        videoAvailable: videoCallsAvailable
      })
    : null;

  function dismissOnboarding() {
    try { window.localStorage.setItem(onboardingStorageKey, "dismissed"); } catch { /* Private or constrained storage must not block dismissal. */ }
    setShowOnboarding(false);
  }

  return (
    <main
      className={`workspace-grid mobile-${mobilePane}`}
      id="main-content"
      style={{
        "--conversation-sidebar-width": `${conversationSidebarWidth}px`
      } as CSSProperties}
    >
      {notice && <div className="workspace-notice" role="status">{notice}<button type="button" aria-label="Dismiss notice" onClick={() => setNotice(null)}><AppIcon name="x" /></button></div>}
      <ConversationSidebar
        activeConversationId={activeConversationId}
        activeCallConversationIds={
          callSessionState?.joined && callTargetConversation?.id
            ? new Set([...activeCallConversationIds, callTargetConversation.id])
            : activeCallConversationIds
        }
        capabilities={capabilities}
        canInviteTeammates={canInviteTeammates}
        conversations={conversations}
        filteredConversations={filteredConversations}
        conversationUsers={conversationUsers}
        conversationQuery={conversationQuery}
        inboxFilter={inboxFilter}
        showBrowseChannels={showBrowseChannels}
        showCreateConversation={showCreateConversation}
        showOnboardingSpotlight={showOnboardingSpotlight}
        showSearch={showSearch}
        needsFirstTeammate={needsFirstTeammate}
        needsTeammateAccessReview={needsTeammateAccessReview}
        humanTeammates={humanTeammates}
        duplicateTeammateNames={duplicateTeammateNames}
        directStartingUserId={directStartingUserId}
        conversationButtonRefs={conversationButtonRefs}
        conversationIdentifier={conversationIdentifier}
        onConversationQueryChange={setConversationQuery}
        onInboxFilterChange={setInboxFilter}
        onToggleBrowseChannels={() => {
          setShowBrowseChannels((visible) => !visible);
          setShowSearch(false);
          setShowDetails(false);
        }}
        onToggleSearch={() => {
          setShowSearch((visible) => !visible);
          setShowBrowseChannels(false);
          setShowDetails(false);
        }}
        onToggleCreateConversation={() =>
          setShowCreateConversation((visible) => !visible)
        }
        onDismissOnboarding={dismissOnboarding}
        onStartDirect={startDirect}
        onCreate={create}
        onSelectConversation={selectConversation}
        onShowCreateConversation={() => {
          setShowCreateConversation(true);
          setShowBrowseChannels(false);
          setShowSearch(false);
        }}
        onShowBrowseChannels={() => {
          setShowBrowseChannels(true);
          setShowCreateConversation(false);
          setShowSearch(false);
        }}
      />

      <ConversationColumnResizer
        width={conversationSidebarWidth}
        onWidthChange={setConversationSidebarWidth}
      />

      <ConversationPane
        activeConversation={activeConversation}
        activeTyping={activeTyping}
        attachmentsReady={attachmentsReady}
        audioCallsAvailable={audioCallsAvailable}
        callGuidance={callGuidance}
        capabilities={capabilities}
        composer={composer}
        connectionStatus={connectionStatus}
        conversationIdentifier={conversationIdentifier}
        currentUserId={session.user.id}
        failedSend={failedSend}
        focusTargetId={focusTarget?.id || null}
        hasOlder={hasOlder}
        isNearBottom={isNearBottom}
        members={conversationMembers}
        mentionedUserIds={mentionedUserIds}
        messages={messages}
        messagesEndRef={messagesEndRef}
        messagesLoading={messagesLoading}
        mobileBackRef={mobileBackRef}
        newMessageCount={newMessageCount}
        olderLoading={olderLoading}
        onlineUsers={onlineUsers}
        pendingAttachments={pendingAttachments}
        readCursors={readCursors}
        deliveryCursors={deliveryCursors}
        whiteboardReference={whiteboardReference}
        replyTo={replyTo}
        scrollRef={scrollRef}
        sending={sending}
        showDetails={showDetails}
        showActivity={showActivity}
        showSearch={showSearch}
        uploading={uploading}
        videoCallsAvailable={videoCallsAvailable}
        visibleSenderIdentifier={visibleSenderIdentifier}
        onAttachmentCancel={cancelAttachment}
        onAttachmentRetry={retryAttachment}
        onComposerChange={composerChanged}
        onDelete={deleteMessage}
        onEdit={editMessage}
        onFilesSelected={filesSelected}
        onInviteGuest={() => {
          setShowGuestShare(true);
          setShowDetails(false);
          setShowSearch(false);
          setShowBrowseChannels(false);
        }}
        onJumpToLatest={jumpToLatest}
        onLoadOlder={loadOlder}
        onMentionedUserIdsChange={setMentionedUserIds}
        onOpenAttachment={(attachment) => void openAttachment(attachment)}
        onReaction={(message, emoji) => void toggleReaction(message, emoji)}
        onReply={(message) => {
          setReplyTo(message);
          document.getElementById("message-composer")?.focus();
        }}
        onReport={(message) => {
          setReportError(null);
          setReportTarget(message);
        }}
        onRequestThumbnail={requestAttachmentThumbnail}
        onRetrySend={retrySend}
        onScroll={messageScrollChanged}
        onSend={sendMessage}
        onShowConversationList={showConversationList}
        onThread={(message) => setThreadTargetId(message.id)}
        onToggleDetails={() => {
          setShowDetails((visible) => !visible);
          setShowGuestShare(false);
        }}
        onToggleActivity={() => {
          setShowActivity((visible) => !visible);
          setShowDetails(false);
          setShowSearch(false);
        }}
        onToggleSearch={() => {
          setShowSearch((visible) => !visible);
          setShowBrowseChannels(false);
          setShowDetails(false);
          setShowGuestShare(false);
        }}
        onClearWhiteboardReference={clearWhiteboardReference}
        setReplyTo={setReplyTo}
      />

      {showSearch && <SearchPanel api={api} conversations={conversations} users={users} onClose={() => setShowSearch(false)} onSelect={(message) => { setFocusTarget({ id: message.id, conversationId: message.conversation_id, sequence: message.conversation_sequence }); setSearchParams({ conversation: message.conversation_id, search_message: message.id, search_sequence: String(message.conversation_sequence) }); setShowDetails(false); setShowBrowseChannels(false); setShowSearch(false); }} />}
      {showBrowseChannels && <ChannelBrowser api={api} enabled={capabilities?.allow_public_channels === true} onClose={() => setShowBrowseChannels(false)} onJoined={(joined) => { setConversations((current) => [joined, ...current.filter((value) => value.id !== joined.id)]); void refreshConversations().catch(() => undefined); }} onOpen={(id) => { selectConversation(id); setShowBrowseChannels(false); }} />}
      {showDetails && activeConversation && <ConversationDetails key={`${activeConversation.id}-${membershipVersion}`} api={api} conversation={activeConversation} currentUserId={session.user.id} users={users} onClose={() => setShowDetails(false)} onLeft={() => { setConversations((current) => current.filter((conversation) => conversation.id !== activeConversation.id)); showConversationList(); void refreshConversations().catch(() => undefined); }} onUpdated={(updated) => setConversations((current) => updated.archived_at ? current.filter((conversation) => conversation.id !== updated.id) : current.map((conversation) => conversation.id === updated.id ? { ...conversation, ...updated } : conversation))} />}
      {showActivity && activeConversation && <ConversationActivityTimeline api={api} conversationId={activeConversation.id} onClose={() => setShowActivity(false)} />}
      {showGuestShare && activeConversation && <ConversationShareDialog api={api} conversation={activeConversation} canPreauthorizeAccount={session.user.role === "owner" || session.user.role === "admin"} runPrivilegedAction={runWithStepUp} onClose={() => setShowGuestShare(false)} />}
      {threadTargetId && activeConversationId && <ThreadDrawer api={api} tenantId={session.tenant.id} conversationId={activeConversationId} targetMessageId={threadTargetId} currentUserId={session.user.id} maxAttachmentBytes={capabilities?.max_attachment_bytes} members={conversationMembers} users={users} retainedSenderLabels={retainedSenderLabelsById} liveMessages={messages} onClose={() => { setThreadTargetId(null); if (searchParams.has("message")) { const next = new URLSearchParams(searchParams); next.delete("message"); setSearchParams(next, { replace: true }); } }} onSend={sendThreadReply} />}
      {reportTarget && <ActionDialog title="Report this message?" description="Describe why workspace moderators should review this message." impact="Moderators will receive the message reference and your explanation. The message is not deleted automatically." confirmLabel="Submit report" auditReason={{ label: "Reason for reporting this message", helpText: "Give moderators enough context to understand the concern.", minimumLength: 1 }} busy={reporting} error={reportError} onCancel={() => { if (!reporting) setReportTarget(null); }} onConfirm={(reason) => void submitReport(reason)} />}
    </main>
  );
}

function readWhiteboardReference(
  params: URLSearchParams
): WhiteboardMessageReference | null {
  const elementIds = (params.get("whiteboard_elements") || "")
    .split(",")
    .filter((id) => id.length >= 8 && id.length <= 128)
    .slice(0, 20);
  const sequence = safePositiveInteger(params.get("whiteboard_sequence"));
  if (elementIds.length === 0 || !sequence) return null;
  const suppliedLabel = (params.get("whiteboard_label") || "").trim().slice(0, 120);
  return {
    element_ids: elementIds,
    board_sequence: sequence,
    label: suppliedLabel || "Whiteboard selection"
  };
}
