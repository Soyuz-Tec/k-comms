import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { ChangeEvent, FormEvent } from "react";
import { Link, useSearchParams } from "react-router";
import type { CreateConversationInput, SendMessageInput } from "../../api";
import { useSession } from "../../app/session";
import { useStepUp } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { ActionDialog } from "../../components/ActionDialog";
import { AppIcon } from "../../components/AppIcon";
import {
  CallLaunchActions,
  useCallSession
} from "../calls/CallSessionProvider";
import { callAvailabilityGuidance } from "../calls/callAvailability";
import {
  clientMessageId,
  conversationTitle,
  errorText
} from "../../lib/format";
import { loadDraft, storeDraft } from "../../lib/drafts";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  participantIdentifier,
  resolveVisibleSenderIdentity,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import { canManageUsers } from "../../lib/roles";
import type { Message } from "../../types";
import { ConversationDetails } from "./ConversationDetails";
import {
  ConversationSidebar,
  type InboxFilter
} from "./ConversationSidebar";
import { ChannelBrowser } from "./ChannelBrowser";
import { MessageItem } from "./MessageItem";
import { MentionPicker } from "./MentionPicker";
import { SearchPanel } from "./SearchPanel";
import { ThreadDrawer } from "./ThreadDrawer";
import {
  canCreateGuestLink,
  ConversationShareDialog
} from "../guest/ConversationShareDialog";
import { AttachmentUploadList } from "./AttachmentUploadList";
import {
  connectionLabel,
  readOnboardingPreference,
  safeCallKind,
  safePositiveInteger,
  safeUuid
} from "./chatSupport";
import { useChatAttachments } from "./useChatAttachments";
import { useConversationFeed } from "./useConversationFeed";
import { useConversationMembers } from "./useConversationMembers";
import "./ChatPage.css";

interface FailedSend {
  input: SendMessageInput;
  body: string;
  draftSnapshot: string;
  error: string;
}

interface FocusTarget {
  id: string;
  conversationId: string;
  sequence: number;
}

export function ChatPage() {
  const { api, session } = useSession();
  const { runWithStepUp } = useStepUp();
  const { launchCall, publishRealtimeEvent } = useCallSession();
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
  const [composer, setComposer] = useState("");
  const [sending, setSending] = useState(false);
  const [failedSend, setFailedSend] = useState<FailedSend | null>(null);
  const [replyTo, setReplyTo] = useState<Message | null>(null);
  const [threadTargetId, setThreadTargetId] = useState<string | null>(null);
  const [mentionedUserIds, setMentionedUserIds] = useState<string[]>([]);
  const [showCreateConversation, setShowCreateConversation] = useState(false);
  const [showSearch, setShowSearch] = useState(false);
  const [showDetails, setShowDetails] = useState(false);
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
  const [isMobile, setIsMobile] = useState(() => window.matchMedia?.("(max-width: 760px)").matches ?? false);
  const activeConversationIdRef = useRef(activeConversationId);
  activeConversationIdRef.current = activeConversationId;
  const forceScrollToLatestRef = useRef(true);
  const typingTimerRef = useRef<number | null>(null);
  const composerRef = useRef(composer);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const mobileBackRef = useRef<HTMLButtonElement | null>(null);
  const draftConversationRef = useRef<string | null>(null);
  const conversationButtonRefs = useRef(new Map<string, HTMLButtonElement>());
  const mobileListFocusConversationRef = useRef<string | null>(null);
  const previousMobileConversationRef = useRef<string | null>(null);
  const directStartUserRef = useRef<string | null>(null);
  const focusComposerAfterDirectRef = useRef(false);
  const activeConversation = useMemo(
    () => conversations.find(({ id }) => id === activeConversationId) || null,
    [activeConversationId, conversations]
  );
  const mobilePane = isMobile && !activeConversation ? "list" : "messages";
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

  useEffect(() => {
    trackVisibleMessages(messages);
  }, [messages, trackVisibleMessages]);

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia("(max-width: 760px)");
    const changed = () => setIsMobile(query.matches);
    changed();
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  }, []);

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
  const messagesById = useMemo(() => new Map(messages.map((message) => [message.id, message])), [messages]);
  useEffect(() => {
    if (!linkedCallKind || !activeConversation) return;
    launchCall(activeConversation, linkedCallKind);
    const next = new URLSearchParams(searchParams);
    next.delete("call");
    setSearchParams(next, { replace: true });
  }, [activeConversation, launchCall, linkedCallKind, searchParams, setSearchParams]);

  useEffect(() => {
    if (workspaceLoading || conversations.length === 0) return;
    if (isMobile) return;
    if (!activeConversationId || !conversations.some(({ id }) => id === activeConversationId)) {
      setSearchParams({ conversation: conversations[0]?.id || "" }, { replace: true });
    }
  }, [activeConversationId, conversations, isMobile, setSearchParams, workspaceLoading]);

  useEffect(() => {
    const previousConversationId = previousMobileConversationRef.current;
    previousMobileConversationRef.current = activeConversation?.id || null;
    if (!isMobile || mobilePane !== "list") return;

    const conversationId = mobileListFocusConversationRef.current || previousConversationId;
    if (!conversationId) return;
    const frame = window.requestAnimationFrame(() => {
      const target = conversationButtonRefs.current.get(conversationId);
      if (!target) return;
      target.focus({ preventScroll: true });
      target.scrollIntoView({ block: "nearest" });
      mobileListFocusConversationRef.current = null;
    });
    return () => window.cancelAnimationFrame(frame);
  }, [activeConversation?.id, isMobile, mobilePane]);

  useEffect(() => {
    if (!isMobile || mobilePane !== "messages") return;
    const frame = window.requestAnimationFrame(() => mobileBackRef.current?.focus({ preventScroll: true }));
    return () => window.cancelAnimationFrame(frame);
  }, [activeConversation?.id, isMobile, mobilePane]);

  useEffect(() => {
    if (!focusComposerAfterDirectRef.current || !activeConversationId) return;
    const frame = window.requestAnimationFrame(() => {
      const composer = document.getElementById("message-composer");
      if (!(composer instanceof HTMLTextAreaElement)) return;
      composer.focus({ preventScroll: true });
      focusComposerAfterDirectRef.current = false;
    });
    return () => window.cancelAnimationFrame(frame);
  }, [activeConversationId, mobilePane]);

  useEffect(() => {
    const previous = draftConversationRef.current;
    if (previous && session) storeDraft(session.tenant.id, session.user.id, previous, composer);
    draftConversationRef.current = activeConversationId;
    forceScrollToLatestRef.current = true;
    const nextComposer = activeConversationId && session
      ? loadDraft(session.tenant.id, session.user.id, activeConversationId)
      : "";
    composerRef.current = nextComposer;
    setComposer(nextComposer);
    setReplyTo(null);
    setThreadTargetId(null);
    setMentionedUserIds([]);
    setFailedSend(null);
    setSending(false);
    resetAttachments();
  }, [activeConversationId, resetAttachments, session?.tenant.id, session?.user.id]);

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
    if (activeConversationId && session) storeDraft(session.tenant.id, session.user.id, activeConversationId, composer);
  }, [activeConversationId, composer, session?.tenant.id, session?.user.id]);

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

  useEffect(() => () => {
    if (typingTimerRef.current) window.clearTimeout(typingTimerRef.current);
  }, []);

  function selectConversation(id: string) {
    setSearchParams({ conversation: id });
    setShowDetails(false);
    setShowBrowseChannels(false);
    setShowGuestShare(false);
  }

  function showConversationList() {
    mobileListFocusConversationRef.current = activeConversation?.id || null;
    setSearchParams({}, { replace: true });
    setShowDetails(false);
    setShowBrowseChannels(false);
    setShowGuestShare(false);
  }

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
      focusComposerAfterDirectRef.current = true;
      selectConversation(conversation.id);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      directStartUserRef.current = null;
      setDirectStartingUserId(null);
    }
  }

  async function sendInput(
    input: SendMessageInput,
    body: string,
    draftSnapshot = body
  ) {
    if (!activeConversationId) return;
    const conversationId = activeConversationId;
    const attachmentReservation = reserveAttachmentsForSend(
      input.attachment_ids || []
    );
    let message: Message;
    try {
      message = await sendCommand(conversationId, input);
    } catch (reason: unknown) {
      attachmentReservation.fail(
        activeConversationIdRef.current !== conversationId
      );
      throw reason;
    }
    attachmentReservation.succeed();
    if (
      session &&
      loadDraft(session.tenant.id, session.user.id, conversationId) ===
        draftSnapshot
    ) {
      storeDraft(session.tenant.id, session.user.id, conversationId, "");
    }
    if (
      activeConversationIdRef.current !== conversationId ||
      composerRef.current !== draftSnapshot
    ) {
      updateConversationSummaries([message]);
      return;
    }
    forceScrollToLatestRef.current = true;
    receiveMessages([message]);
    composerRef.current = "";
    setComposer("");
    clearPendingAttachments();
    setReplyTo(null);
    setMentionedUserIds([]);
    setFailedSend(null);
    void body;
  }

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!activeConversationId || sending) return;
    const body = composer.trim();
    if (!body) return setError("Write a message before sending.");
    if (!attachmentsReady) return setError("Wait for every attachment safety scan to finish or remove the file.");
    const input: SendMessageInput = {
      client_message_id: clientMessageId(),
      body,
      attachment_ids: readyAttachmentIds,
      reply_to_message_id: replyTo?.id || null,
      mentioned_user_ids: mentionedUserIds
    };
    setSending(true);
    setError(null);
    setConversationTyping(false);
    const conversationId = activeConversationId;
    try {
      await sendInput(input, body, composer);
    } catch (reason: unknown) {
      if (activeConversationIdRef.current === conversationId) {
        const message = errorText(reason);
        setFailedSend({ input, body, draftSnapshot: composer, error: message });
        setError(message);
      }
    } finally {
      if (activeConversationIdRef.current === conversationId) {
        setSending(false);
      }
    }
  }

  async function retrySend() {
    if (!failedSend || sending) return;
    setSending(true);
    setError(null);
    const conversationId = activeConversationId;
    try {
      await sendInput(
        failedSend.input,
        failedSend.body,
        failedSend.draftSnapshot
      );
    } catch (reason: unknown) {
      if (activeConversationIdRef.current === conversationId) {
        const message = errorText(reason);
        setFailedSend({ ...failedSend, error: message });
        setError(message);
      }
    } finally {
      if (activeConversationIdRef.current === conversationId) {
        setSending(false);
      }
    }
  }

  async function sendThreadReply(input: SendMessageInput): Promise<Message> {
    if (!activeConversationId) throw new Error("Select a conversation before replying.");
    const conversationId = activeConversationId;
    const message = await sendCommand(conversationId, input);
    if (activeConversationIdRef.current === conversationId) {
      forceScrollToLatestRef.current = true;
      receiveMessages([message]);
    } else {
      updateConversationSummaries([message]);
    }
    return message;
  }

  function composerChanged(event: ChangeEvent<HTMLTextAreaElement>) {
    composerRef.current = event.target.value;
    setComposer(event.target.value);
    setConversationTyping(true);
    if (typingTimerRef.current) window.clearTimeout(typingTimerRef.current);
    typingTimerRef.current = window.setTimeout(
      () => setConversationTyping(false),
      1_500
    );
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
    <main className={`workspace-grid mobile-${mobilePane}`} id="main-content">
      {notice && <div className="workspace-notice" role="status">{notice}<button type="button" aria-label="Dismiss notice" onClick={() => setNotice(null)}><AppIcon name="x" /></button></div>}
      <ConversationSidebar
        activeConversationId={activeConversationId}
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

      <section className="conversation-pane" aria-label={activeConversation ? conversationIdentifier(activeConversation) : "Messages"}>
        {activeConversation ? <>
          <header className="conversation-header">
            <button ref={mobileBackRef} className="mobile-back" type="button" onClick={showConversationList} aria-label="Back to conversations"><AppIcon name="arrowLeft" /></button>
            <div>
              <span className="eyebrow">{activeConversation.kind} · {activeConversation.visibility}</span>
              <h2 data-route-focus>{conversationIdentifier(activeConversation)}</h2>
            </div>
            <div className="conversation-header-actions">
              <div className="connection-summary" aria-live="polite"><span className={`status-dot ${connectionStatus}`} aria-hidden="true" /><span>{connectionLabel(connectionStatus)}</span>{onlineUsers > 0 && <small>{onlineUsers} online</small>}</div>
              <button className="icon-button mobile-header-search" type="button" aria-label="Search messages" aria-expanded={showSearch} onClick={() => { setShowSearch((visible) => !visible); setShowBrowseChannels(false); setShowDetails(false); setShowGuestShare(false); }}><AppIcon name="search" /></button>
              <CallLaunchActions
                conversation={activeConversation}
                audioEnabled={capabilities?.allow_audio_calls === true && audioCallsAvailable}
                videoEnabled={capabilities?.allow_video_calls === true && videoCallsAvailable}
                availabilityDescriptionId={callGuidance ? "conversation-call-availability" : undefined}
              />
              {(activeConversation.kind === "direct" || canCreateGuestLink(activeConversation)) && <button className="button ghost compact" type="button" aria-haspopup="dialog" onClick={() => { setShowGuestShare(true); setShowDetails(false); setShowSearch(false); setShowBrowseChannels(false); }}><AppIcon name="userPlus" />Invite guest</button>}
              <button className="button ghost compact" type="button" aria-expanded={showDetails} onClick={() => { setShowDetails((visible) => !visible); setShowGuestShare(false); }}><AppIcon name="more" />Details</button>
            </div>
          </header>
          {callGuidance && (
            <p className="call-availability-guidance conversation-call-guidance" id="conversation-call-availability" role="status">
              <span>{callGuidance}</span>
              <Link to="/app/calls">Open Calls</Link>
            </p>
          )}
          <div className="message-scroll" ref={scrollRef} aria-busy={messagesLoading} onScroll={messageScrollChanged}>
            {hasOlder && <div className="history-loader"><button className="button ghost compact" type="button" disabled={olderLoading} onClick={() => void loadOlder(scrollRef.current)}>{olderLoading ? "Loading…" : "Load older messages"}</button></div>}
            {messagesLoading && messages.length === 0 ? <div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading messages…</div> : messages.length === 0 ? <div className="empty-state"><span className="empty-mark" aria-hidden="true"><AppIcon name="sparkles" /></span><h3>Start the conversation</h3><p>Messages are durable, ordered, and replayed when you reconnect.</p></div> : <ol className="message-list">{messages.map((message) => { const replyPreview = message.reply_to_message_id ? messagesById.get(message.reply_to_message_id) : undefined; const senderName = visibleSenderIdentifier(message.sender_user_id); const replySenderName = replyPreview ? visibleSenderIdentifier(replyPreview.sender_user_id) : undefined; return <MessageItem key={message.id} message={message} currentUserId={session.user.id} senderName={senderName} replyPreview={replyPreview} replySenderName={replySenderName} seenCount={Object.entries(readCursors).filter(([userId, sequence]) => userId !== session.user.id && sequence >= message.conversation_sequence).length} focused={focusTarget?.id === message.id} onReaction={(emoji) => void toggleReaction(message, emoji)} onAttachment={(attachment) => void openAttachment(attachment)} onRequestThumbnail={requestAttachmentThumbnail} onReply={() => { setReplyTo(message); document.getElementById("message-composer")?.focus(); }} onThread={() => setThreadTargetId(message.id)} onEdit={(body) => editMessage(message, body)} onDelete={() => deleteMessage(message)} onReport={() => { setReportError(null); setReportTarget(message); }} />; })}</ol>}
            <div ref={messagesEndRef} />
          </div>
          <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">{newMessageCount > 0 ? `${newMessageCount} new ${newMessageCount === 1 ? "message" : "messages"}.` : ""}</p>
          {!isNearBottom && <div className="new-message-jump"><button className="button primary compact" type="button" onClick={jumpToLatest}>{newMessageCount > 0 ? `${newMessageCount} new ${newMessageCount === 1 ? "message" : "messages"} · Jump to latest` : "Jump to latest"}</button></div>}
          <div className="typing-line" aria-live="polite">{activeTyping.length > 0 ? `${activeTyping.join(", ")} ${activeTyping.length === 1 ? "is" : "are"} typing…` : "\u00a0"}</div>
          <form className="composer" onSubmit={(event) => void sendMessage(event)}>
            {failedSend && <div className="failed-send" role="alert"><span>Message not sent. Your draft is safe. {failedSend.error}</span><button className="button ghost compact" type="button" disabled={sending} onClick={() => void retrySend()}>Retry</button></div>}
            {replyTo && <div className="composer-reply"><span>Replying to <strong>{replyTo.sender_user_id === session.user.id ? "yourself" : visibleSenderIdentifier(replyTo.sender_user_id) || "a message"}</strong><small>{replyTo.body}</small></span><button type="button" aria-label="Cancel reply" onClick={() => setReplyTo(null)}><AppIcon name="x" /></button></div>}
            {pendingAttachments.length > 0 && <AttachmentUploadList items={pendingAttachments} onCancel={cancelAttachment} onRetry={retryAttachment} />}
            <MentionPicker members={conversationMembers} currentUserId={session.user.id} selectedUserIds={mentionedUserIds} disabled={sending} onChange={setMentionedUserIds} />
            <label className="sr-only" htmlFor="message-composer">Message</label><textarea id="message-composer" value={composer} onChange={composerChanged} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} rows={2} maxLength={65_535} placeholder={`Message ${conversationIdentifier(activeConversation)}`} disabled={sending} />
            <div className="composer-actions"><label className={`attachment-button ${sending ? "disabled" : ""}`}><input type="file" multiple disabled={sending} onChange={(event) => void filesSelected(event)} accept="image/*,text/*,application/pdf,application/zip,application/json" aria-label="Attach files" /><AppIcon name="paperclip" />Attach</label><span className="composer-hint">Draft saved · Enter to send · Shift+Enter for a new line</span><button className="button primary send-button" type="submit" disabled={sending || uploading || !attachmentsReady || !composer.trim()}>{sending ? "Sending…" : "Send"}<AppIcon name="send" /></button></div>
          </form>
        </> : <div className="empty-state full-height"><span className="empty-mark" aria-hidden="true"><AppIcon name="message" /></span><h2>Select a conversation</h2><p>Choose a direct message, group or channel.</p></div>}
      </section>

      {showSearch && <SearchPanel api={api} conversations={conversations} users={users} onClose={() => setShowSearch(false)} onSelect={(message) => { setFocusTarget({ id: message.id, conversationId: message.conversation_id, sequence: message.conversation_sequence }); setSearchParams({ conversation: message.conversation_id, search_message: message.id, search_sequence: String(message.conversation_sequence) }); setShowDetails(false); setShowBrowseChannels(false); setShowSearch(false); }} />}
      {showBrowseChannels && <ChannelBrowser api={api} enabled={capabilities?.allow_public_channels === true} onClose={() => setShowBrowseChannels(false)} onJoined={(joined) => { setConversations((current) => [joined, ...current.filter((value) => value.id !== joined.id)]); void refreshConversations().catch(() => undefined); }} onOpen={(id) => { selectConversation(id); setShowBrowseChannels(false); }} />}
      {showDetails && activeConversation && <ConversationDetails key={`${activeConversation.id}-${membershipVersion}`} api={api} conversation={activeConversation} currentUserId={session.user.id} users={users} onClose={() => setShowDetails(false)} onLeft={() => { setConversations((current) => current.filter((conversation) => conversation.id !== activeConversation.id)); showConversationList(); void refreshConversations().catch(() => undefined); }} onUpdated={(updated) => setConversations((current) => updated.archived_at ? current.filter((conversation) => conversation.id !== updated.id) : current.map((conversation) => conversation.id === updated.id ? { ...conversation, ...updated } : conversation))} />}
      {showGuestShare && activeConversation && <ConversationShareDialog api={api} conversation={activeConversation} canPreauthorizeAccount={session.user.role === "owner" || session.user.role === "admin"} runPrivilegedAction={runWithStepUp} onClose={() => setShowGuestShare(false)} />}
      {threadTargetId && activeConversationId && <ThreadDrawer api={api} tenantId={session.tenant.id} conversationId={activeConversationId} targetMessageId={threadTargetId} currentUserId={session.user.id} maxAttachmentBytes={capabilities?.max_attachment_bytes} members={conversationMembers} users={users} retainedSenderLabels={retainedSenderLabelsById} liveMessages={messages} onClose={() => { setThreadTargetId(null); if (searchParams.has("message")) { const next = new URLSearchParams(searchParams); next.delete("message"); setSearchParams(next, { replace: true }); } }} onSend={sendThreadReply} />}
      {reportTarget && <ActionDialog title="Report this message?" description="Describe why workspace moderators should review this message." impact="Moderators will receive the message reference and your explanation. The message is not deleted automatically." confirmLabel="Submit report" auditReason={{ label: "Reason for reporting this message", helpText: "Give moderators enough context to understand the concern.", minimumLength: 1 }} busy={reporting} error={reportError} onCancel={() => { if (!reporting) setReportTarget(null); }} onConfirm={(reason) => void submitReport(reason)} />}
    </main>
  );
}

