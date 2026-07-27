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
import {
  downloadUrl,
  sha256,
  uploadToPresignedTarget
} from "../../api";
import { useSession } from "../../app/session";
import { useStepUp } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { ActionDialog } from "../../components/ActionDialog";
import {
  CallLaunchActions,
  useCallSession
} from "../calls/CallSessionProvider";
import {
  clientMessageId,
  conversationTitle,
  errorText,
  formatTime
} from "../../lib/format";
import { loadDraft, storeDraft } from "../../lib/drafts";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  mergeRetainedSenderLabelMaps,
  participantIdentifier,
  resolveVisibleSenderIdentity,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import { canManageUsers } from "../../lib/roles";
import { RealtimeConversation, socketEndpoint } from "../../realtime";
import type {
  Attachment,
  ConnectionStatus,
  ConversationMembership,
  Message,
  ReactionEvent,
  ReadCursorEvent,
  RetainedSenderLabel
} from "../../types";
import { ConversationDetails } from "./ConversationDetails";
import { ChannelBrowser } from "./ChannelBrowser";
import { CreateConversationForm } from "./CreateConversationForm";
import { MessageItem } from "./MessageItem";
import { MentionPicker } from "./MentionPicker";
import { SearchPanel } from "./SearchPanel";
import { ThreadDrawer } from "./ThreadDrawer";
import {
  canCreateGuestLink,
  ConversationShareDialog
} from "../guest/ConversationShareDialog";
import {
  AttachmentUploadList,
  attachmentUploadBusy,
  attachmentUploadReady
} from "./AttachmentUploadList";
import type {
  PendingAttachmentUpload
} from "./AttachmentUploadList";
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

type InboxFilter = "all" | "unread" | "direct" | "rooms";

const senderLabelRefreshDelaysMs = [30_000, 60_000, 120_000, 300_000] as const;

interface SenderLabelRefreshBackoff {
  conversationId: string | null;
  candidateSignature: string | null;
  resultSignature: string | null;
  delayIndex: number;
  nextAttemptAt: number;
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
  const [messages, setMessages] = useState<Message[]>([]);
  const [retainedSenderLabelsById, setRetainedSenderLabelsById] = useState(
    () => new Map<string, RetainedSenderLabel>()
  );
  const [messagesLoading, setMessagesLoading] = useState(false);
  const [olderLoading, setOlderLoading] = useState(false);
  const [hasOlder, setHasOlder] = useState(false);
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>("offline");
  const [onlineUsers, setOnlineUsers] = useState(0);
  const [typingUsers, setTypingUsers] = useState<Set<string>>(() => new Set());
  const [readCursors, setReadCursors] = useState<Record<string, number>>({});
  const [composer, setComposer] = useState("");
  const [sending, setSending] = useState(false);
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachmentUpload[]>([]);
  const [failedSend, setFailedSend] = useState<FailedSend | null>(null);
  const [replyTo, setReplyTo] = useState<Message | null>(null);
  const [threadTargetId, setThreadTargetId] = useState<string | null>(null);
  const [conversationMembers, setConversationMembers] = useState<ConversationMembership[]>([]);
  const [conversationMemberIdentities, setConversationMemberIdentities] =
    useState<{
      conversationId: string | null;
      usersById: Map<string, ParticipantIdentity>;
    }>(() => ({ conversationId: null, usersById: new Map() }));
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
  const [contiguousSequence, setContiguousSequence] = useState(0);
  const [conversationQuery, setConversationQuery] = useState("");
  const [inboxFilter, setInboxFilter] = useState<InboxFilter>("all");
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const [showOnboarding, setShowOnboarding] = useState(() => session ? readOnboardingPreference(onboardingStorageKey) : false);
  const [directStartingUserId, setDirectStartingUserId] = useState<string | null>(null);
  const [isMobile, setIsMobile] = useState(() => window.matchMedia?.("(max-width: 760px)").matches ?? false);
  const realtimeRef = useRef<RealtimeConversation | null>(null);
  const activeConversationIdRef = useRef(activeConversationId);
  activeConversationIdRef.current = activeConversationId;
  const contiguousSequenceRef = useRef(0);
  const futureSequencesRef = useRef<Set<number>>(new Set());
  const knownMessageIdsRef = useRef<Set<string>>(new Set());
  const conversationMembersRequestGenerationRef = useRef(0);
  const conversationMembersInFlightRef = useRef<{
    conversationId: string;
    token: symbol;
  } | null>(null);
  const conversationMembersPendingRef = useRef<string | null>(null);
  const scheduleConversationMembersRefreshRef = useRef<
    (conversationId: string) => void
  >(() => undefined);
  const conversationMembersReloadTimerRef = useRef<{
    conversationId: string;
    timer: number;
  } | null>(null);
  const conversationMemberIdsSignatureRef = useRef<{
    conversationId: string;
    signature: string;
  } | null>(null);
  const visibleMessageAuthorsRef = useRef<{
    conversationId: string;
    authors: Array<{ senderUserId: string; messageId: string }>;
  } | null>(null);
  const senderLabelRefreshBackoffRef = useRef<SenderLabelRefreshBackoff>(
    newSenderLabelRefreshBackoff(activeConversationId)
  );
  const presenceUserIdsSignatureRef = useRef<string | null>(null);
  const loadOlderRequestGenerationRef = useRef(0);
  const nearBottomRef = useRef(true);
  const forceScrollToLatestRef = useRef(true);
  const typingTimerRef = useRef<number | null>(null);
  const composerRef = useRef(composer);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const mobileBackRef = useRef<HTMLButtonElement | null>(null);
  const draftConversationRef = useRef<string | null>(null);
  const requestCatchUpRef = useRef<(
    afterSequence?: number,
    beforeSequence?: number
  ) => void>(() => undefined);
  const conversationButtonRefs = useRef(new Map<string, HTMLButtonElement>());
  const mobileListFocusConversationRef = useRef<string | null>(null);
  const previousMobileConversationRef = useRef<string | null>(null);
  const directStartUserRef = useRef<string | null>(null);
  const focusComposerAfterDirectRef = useRef(false);
  const cancelledAttachmentUploadsRef = useRef(new Set<string>());
  const attachmentUploadControllersRef = useRef(new Map<string, AbortController>());
  const attachmentIntentIdsRef = useRef(new Map<string, string>());
  const sendingAttachmentIdsRef = useRef(new Set<string>());
  const attachmentAbandonRequestsRef = useRef(new Map<string, Promise<void>>());
  const chatMountedRef = useRef(true);
  const abandonAttachmentId = useCallback((id: string): Promise<void> => {
    const existing = attachmentAbandonRequestsRef.current.get(id);
    if (existing) return existing;

    const request = (async () => {
      let lastReason: unknown = new Error("The attachment could not be removed");
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          await api.abandonAttachment(id);
          return;
        } catch (reason: unknown) {
          lastReason = reason;
          if (attempt < 2) await delay(250 * (attempt + 1));
        }
      }
      throw lastReason;
    })().finally(() => {
      attachmentAbandonRequestsRef.current.delete(id);
    });

    attachmentAbandonRequestsRef.current.set(id, request);
    return request;
  }, [api]);
  const abandonClientAttachment = useCallback(async (clientId: string): Promise<void> => {
    const id = attachmentIntentIdsRef.current.get(clientId);
    if (!id) return;
    await abandonAttachmentId(id);
    if (attachmentIntentIdsRef.current.get(clientId) === id) {
      attachmentIntentIdsRef.current.delete(clientId);
    }
  }, [abandonAttachmentId]);
  const abandonClientAttachmentInBackground = useCallback((clientId: string) => {
    void abandonClientAttachment(clientId).catch(() => {
      if (chatMountedRef.current) {
        setError("A cancelled file is still awaiting secure cleanup. The server will keep retrying automatically.");
      }
    });
  }, [abandonClientAttachment]);
  const cancelAllAttachmentUploads = useCallback(() => {
    for (const [clientId, controller] of attachmentUploadControllersRef.current) {
      cancelledAttachmentUploadsRef.current.add(clientId);
      controller.abort();
    }
    attachmentUploadControllersRef.current.clear();
    for (const clientId of attachmentIntentIdsRef.current.keys()) {
      const attachmentId = attachmentIntentIdsRef.current.get(clientId);
      if (attachmentId && sendingAttachmentIdsRef.current.has(attachmentId)) {
        continue;
      }
      cancelledAttachmentUploadsRef.current.add(clientId);
      abandonClientAttachmentInBackground(clientId);
    }
  }, [abandonClientAttachmentInBackground]);

  useEffect(() => {
    chatMountedRef.current = true;
    return () => {
      chatMountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia("(max-width: 760px)");
    const changed = () => setIsMobile(query.matches);
    changed();
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  }, []);

  const activeConversation = useMemo(
    () => conversations.find(({ id }) => id === activeConversationId) || null,
    [activeConversationId, conversations]
  );
  const mobilePane = isMobile && !activeConversation ? "list" : "messages";
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
  const conversationMemberUsersById = useMemo(
    () =>
      conversationMemberIdentities.conversationId === activeConversationId
        ? conversationMemberIdentities.usersById
        : new Map<string, ParticipantIdentity>(),
    [activeConversationId, conversationMemberIdentities]
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
  const mergeRetainedSenderLabels = useCallback((
    incoming: RetainedSenderLabel[] | undefined
  ) => {
    if (!incoming || incoming.length === 0) return;
    setRetainedSenderLabelsById((current) =>
      mergeRetainedSenderLabelMaps(current, incoming)
    );
  }, []);

  useEffect(() => {
    if (!linkedCallKind || !activeConversation) return;
    launchCall(activeConversation, linkedCallKind);
    const next = new URLSearchParams(searchParams);
    next.delete("call");
    setSearchParams(next, { replace: true });
  }, [activeConversation, launchCall, linkedCallKind, searchParams, setSearchParams]);

  const updateNearBottom = useCallback((nearBottom: boolean) => {
    nearBottomRef.current = nearBottom;
    setIsNearBottom(nearBottom);
    if (nearBottom) setNewMessageCount(0);
  }, []);

  const refreshConversationMembers = useCallback(async (
    conversationId: string,
    clearCurrent = false
  ): Promise<void> => {
    if (
      conversationMembersInFlightRef.current?.conversationId === conversationId
    ) {
      conversationMembersPendingRef.current = conversationId;
      conversationMembersRequestGenerationRef.current += 1;
      return;
    }
    const requestToken = Symbol(conversationId);
    conversationMembersInFlightRef.current = {
      conversationId,
      token: requestToken
    };
    const requestGeneration =
      ++conversationMembersRequestGenerationRef.current;
    if (clearCurrent) {
      setConversationMembers([]);
      setConversationMemberIdentities({
        conversationId,
        usersById: new Map()
      });
    }
    try {
      const members = await api.conversationMembers(conversationId);
      if (
        requestGeneration !== conversationMembersRequestGenerationRef.current ||
        activeConversationIdRef.current !== conversationId
      ) {
        return;
      }
      setConversationMembers(members);
      setConversationMemberIdentities((current) => {
        const usersById =
          current.conversationId === conversationId
            ? new Map(current.usersById)
            : new Map<string, ParticipantIdentity>();
        for (const { user } of members) usersById.set(user.id, user);
        return { conversationId, usersById };
      });
      const memberIdsSignature = members
        .map(({ user }) => user.id)
        .sort()
        .join("\u0000");
      const previousSignature = conversationMemberIdsSignatureRef.current;
      conversationMemberIdsSignatureRef.current = {
        conversationId,
        signature: memberIdsSignature
      };
      if (
        previousSignature?.conversationId === conversationId
      ) {
        const visibleAuthors = visibleMessageAuthorsRef.current;
        const activeUserIds = new Set(members.map(({ user }) => user.id));
        const departedAuthorMessageIds =
          visibleAuthors?.conversationId === conversationId
            ? visibleAuthors.authors
                .filter(({ senderUserId }) => !activeUserIds.has(senderUserId))
                .map(({ messageId }) => messageId)
            : [];
        if (
          departedAuthorMessageIds.length > 0
        ) {
          if (
            !senderLabelRefreshAllowed(
              senderLabelRefreshBackoffRef,
              conversationId,
              departedAuthorMessageIds
            )
          ) {
            return;
          }
          try {
            const labels = await api.messageSenderLabels(
              conversationId,
              departedAuthorMessageIds
            );
            if (
              requestGeneration === conversationMembersRequestGenerationRef.current &&
              activeConversationIdRef.current === conversationId
            ) {
              mergeRetainedSenderLabels(labels);
              recordSenderLabelRefresh(
                senderLabelRefreshBackoffRef,
                conversationId,
                departedAuthorMessageIds,
                labels
              );
            }
          } catch (reason: unknown) {
            if (
              requestGeneration === conversationMembersRequestGenerationRef.current &&
              activeConversationIdRef.current === conversationId
            ) {
              setError(errorText(reason));
            }
          }
        }
      }
    } catch (reason: unknown) {
      if (
        requestGeneration === conversationMembersRequestGenerationRef.current &&
        activeConversationIdRef.current === conversationId
      ) {
        setError(errorText(reason));
      }
    } finally {
      if (
        conversationMembersInFlightRef.current?.token === requestToken
      ) {
        conversationMembersInFlightRef.current = null;
        if (
          conversationMembersPendingRef.current === conversationId &&
          activeConversationIdRef.current === conversationId
        ) {
          conversationMembersPendingRef.current = null;
          scheduleConversationMembersRefreshRef.current(conversationId);
        }
      }
    }
  }, [api, mergeRetainedSenderLabels, setError]);

  const cancelScheduledConversationMembersRefresh = useCallback(() => {
    if (conversationMembersReloadTimerRef.current === null) return;
    window.clearTimeout(conversationMembersReloadTimerRef.current.timer);
    conversationMembersReloadTimerRef.current = null;
  }, []);

  const scheduleConversationMembersRefresh = useCallback((
    conversationId: string
  ) => {
    const scheduled = conversationMembersReloadTimerRef.current;
    if (scheduled?.conversationId === conversationId) return;
    if (scheduled) window.clearTimeout(scheduled.timer);
    const timer = window.setTimeout(() => {
      if (conversationMembersReloadTimerRef.current?.timer !== timer) return;
      conversationMembersReloadTimerRef.current = null;
      if (activeConversationIdRef.current === conversationId) {
        void refreshConversationMembers(conversationId);
      }
    }, 0);
    conversationMembersReloadTimerRef.current = { conversationId, timer };
  }, [refreshConversationMembers]);
  scheduleConversationMembersRefreshRef.current =
    scheduleConversationMembersRefresh;

  useEffect(() => {
    cancelScheduledConversationMembersRefresh();
    presenceUserIdsSignatureRef.current = null;
    conversationMemberIdsSignatureRef.current = null;
    senderLabelRefreshBackoffRef.current =
      newSenderLabelRefreshBackoff(activeConversationId);
    conversationMembersPendingRef.current = null;
    conversationMembersInFlightRef.current = null;
    if (!activeConversationId) {
      conversationMembersRequestGenerationRef.current += 1;
      setConversationMembers([]);
      setConversationMemberIdentities({
        conversationId: null,
        usersById: new Map()
      });
      return;
    }
    const conversationId = activeConversationId;
    void refreshConversationMembers(conversationId, true);
    const reconciliationTimer = window.setInterval(
      () => scheduleConversationMembersRefresh(conversationId),
      30_000
    );
    return () => {
      window.clearInterval(reconciliationTimer);
      cancelScheduledConversationMembersRefresh();
      presenceUserIdsSignatureRef.current = null;
      conversationMemberIdsSignatureRef.current = null;
      conversationMembersPendingRef.current = null;
      conversationMembersInFlightRef.current = null;
      conversationMembersRequestGenerationRef.current += 1;
    };
  }, [
    activeConversationId,
    cancelScheduledConversationMembersRefresh,
    refreshConversationMembers,
    scheduleConversationMembersRefresh
  ]);

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
    knownMessageIdsRef.current.clear();
    nearBottomRef.current = true;
    forceScrollToLatestRef.current = true;
    setIsNearBottom(true);
    setNewMessageCount(0);
    loadOlderRequestGenerationRef.current += 1;
    setOlderLoading(false);
    setHasOlder(false);
    setRetainedSenderLabelsById(new Map());
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
    cancelAllAttachmentUploads();
    setPendingAttachments([]);
  }, [activeConversationId, cancelAllAttachmentUploads, session?.tenant.id, session?.user.id]);

  useEffect(() => {
    const authorMessageIds = new Map<string, string>();
    for (const message of messages) {
      if (!authorMessageIds.has(message.sender_user_id)) {
        authorMessageIds.set(message.sender_user_id, message.id);
      }
    }
    visibleMessageAuthorsRef.current = activeConversationId && authorMessageIds.size > 0
      ? {
          conversationId: activeConversationId,
          authors: [...authorMessageIds]
            .map(([senderUserId, messageId]) => ({ senderUserId, messageId }))
            .sort((left, right) => left.senderUserId.localeCompare(right.senderUserId))
        }
      : null;
  }, [activeConversationId, messages]);

  useEffect(() => () => cancelAllAttachmentUploads(), [cancelAllAttachmentUploads]);

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

  const updateConversationSummaries = useCallback(
    (incoming: Message[]) => {
      const activityByConversation = new Map<
        string,
        { latest: number; hasMessageFromOther: boolean }
      >();
      for (const message of incoming) {
        const current = activityByConversation.get(message.conversation_id);
        activityByConversation.set(
          message.conversation_id,
          {
            latest: Math.max(current?.latest || 0, message.conversation_sequence),
            hasMessageFromOther:
              current?.hasMessageFromOther === true ||
              message.sender_user_id !== session?.user.id
          }
        );
      }
      if (activityByConversation.size === 0) return;
      setConversations((current) =>
        current.map((conversation) => {
          const activity = activityByConversation.get(conversation.id);
          if (!activity) return conversation;
          const latestSequence = Math.max(
            conversation.latest_sequence,
            activity.latest
          );
          const shouldRemainUnread =
            conversation.id !== activeConversationIdRef.current ||
            document.visibilityState !== "visible" ||
            !nearBottomRef.current;
          return {
            ...conversation,
            latest_sequence: latestSequence,
            unread_count: shouldRemainUnread && activity.hasMessageFromOther
              ? Math.max(
                  conversation.unread_count || 0,
                  latestSequence - (conversation.last_read_sequence || 0)
                )
              : conversation.unread_count
          };
        })
      );
    },
    [session?.user.id, setConversations]
  );

  const receiveMessages = useCallback(
    (incoming: Message[]) => {
      if (incoming.length === 0) return;
      updateConversationSummaries(incoming);
      const activeConversationId = activeConversationIdRef.current;
      const activeIncoming = activeConversationId
        ? incoming.filter(
            (message) => message.conversation_id === activeConversationId
          )
        : [];
      if (activeIncoming.length === 0) return;
      const newMessagesFromOthers = activeIncoming.filter(
        (message) => !knownMessageIdsRef.current.has(message.id) && message.sender_user_id !== session?.user.id
      ).length;
      activeIncoming.forEach((message) => knownMessageIdsRef.current.add(message.id));
      if (!nearBottomRef.current && newMessagesFromOthers > 0) {
        setNewMessageCount((count) => count + newMessagesFromOthers);
      }
      for (const message of activeIncoming) {
        if (message.conversation_sequence > contiguousSequenceRef.current) {
          futureSequencesRef.current.add(message.conversation_sequence);
        }
      }
      let nextContiguous = contiguousSequenceRef.current;
      while (futureSequencesRef.current.delete(nextContiguous + 1)) {
        nextContiguous += 1;
      }
      if (nextContiguous !== contiguousSequenceRef.current) {
        contiguousSequenceRef.current = nextContiguous;
        setContiguousSequence(nextContiguous);
      }
      if (futureSequencesRef.current.size > 0) requestCatchUpRef.current();

      setMessages((current) => {
        const byId = new Map(current.map((message) => [message.id, message]));
        activeIncoming.forEach((message) => {
          byId.set(message.id, message);
          if (message.thread_root_message_id) {
            const root = byId.get(message.thread_root_message_id);
            if (root) {
              byId.set(root.id, {
                ...root,
                thread_reply_count: Math.max(
                  root.thread_reply_count || 0,
                  message.thread_reply_count || 0
                )
              });
            }
          }
        });
        return [...byId.values()].sort(
          (left, right) => left.conversation_sequence - right.conversation_sequence
        );
      });

    },
    [session?.user.id, updateConversationSummaries]
  );

  const applyReaction = useCallback((event: ReactionEvent, add: boolean) => {
    setMessages((current) =>
      current.map((message) => {
        if (message.id !== event.message_id) return message;
        const without = message.reactions.filter(
          (reaction) => !(reaction.user_id === event.user_id && reaction.emoji === event.emoji)
        );
        return { ...message, reactions: add ? [...without, { user_id: event.user_id, emoji: event.emoji }] : without };
      })
    );
  }, []);

  useEffect(() => {
    if (!session || !activeConversationId || !activeConversation) return;
    const conversationId = activeConversationId;
    const activeLatestSequence = activeConversation.latest_sequence;
    const realtimeDisabled = import.meta.env.VITE_DISABLE_REALTIME === "true";
    let current = true;
    let realtime: RealtimeConversation | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempts = 0;
    let catchUpRetryTimer: number | null = null;
    let catchUpRetryAttempts = 0;
    let catchUpInFlight = false;
    type CatchUpRequest = {
      afterSequence: number;
      beforeSequence?: number;
    };
    let pendingCatchUpRequest: CatchUpRequest | null = null;
    setMessages([]);
    knownMessageIdsRef.current.clear();
    setTypingUsers(new Set());
    setReadCursors({});
    setMessagesLoading(true);
    setConnectionStatus("connecting");
    setError(null);
    futureSequencesRef.current.clear();

    async function catchUp(afterSequence: number, beforeSequence?: number) {
      let cursor = afterSequence;
      for (let pages = 0; current && pages < 500; pages += 1) {
        const page = beforeSequence === undefined
          ? await api.messages(conversationId, cursor, 200)
          : await api.messages(conversationId, cursor, 200, beforeSequence);
        if (!current) return;
        mergeRetainedSenderLabels(page.included?.sender_labels);
        receiveMessages(page.data);
        if (!page.page.has_more) return;
        const next = page.page.next_after_sequence;
        if (next === null || next <= cursor) throw new Error("Realtime replay returned a non-advancing cursor.");
        cursor = next;
      }
      if (current) throw new Error("Realtime replay exceeded the safe catch-up limit.");
    }

    const requestCatchUp = (
      afterSequence = contiguousSequenceRef.current,
      beforeSequence?: number
    ) => {
      if (!current) return;
      const pending = pendingCatchUpRequest;
      pendingCatchUpRequest = pending
        ? {
            afterSequence: Math.min(pending.afterSequence, afterSequence),
            beforeSequence:
              pending.beforeSequence === undefined || beforeSequence === undefined
                ? undefined
                : Math.max(pending.beforeSequence, beforeSequence)
          }
        : { afterSequence, beforeSequence };
      if (catchUpInFlight) return;
      catchUpInFlight = true;
      let failed = false;
      let requestInFlight: CatchUpRequest | null = null;

      const drainCatchUpRequests = async () => {
        while (current && pendingCatchUpRequest !== null) {
          const requested = pendingCatchUpRequest;
          requestInFlight = requested;
          pendingCatchUpRequest = null;
          const before = contiguousSequenceRef.current;
          await catchUp(requested.afterSequence, requested.beforeSequence);
          requestInFlight = null;
          catchUpRetryAttempts = 0;
          if (
            current &&
            futureSequencesRef.current.size > 0 &&
            contiguousSequenceRef.current === before
          ) {
            pendingCatchUpRequest = null;
            setError("Durable message replay could not close a sequence gap. Reconnecting…");
            scheduleReconnect();
            return;
          }
        }
      };

      void drainCatchUpRequests()
        .catch((reason: unknown) => {
          if (current) {
            failed = true;
            if (requestInFlight) {
              const pending = pendingCatchUpRequest;
              pendingCatchUpRequest = pending
                ? {
                    afterSequence: Math.min(
                      requestInFlight.afterSequence,
                      pending.afterSequence
                    ),
                    beforeSequence:
                      requestInFlight.beforeSequence === undefined ||
                      pending.beforeSequence === undefined
                        ? undefined
                        : Math.max(
                            requestInFlight.beforeSequence,
                            pending.beforeSequence
                          )
                  }
                : requestInFlight;
            }
            setError(`${errorText(reason)} Retrying durable replay…`);
          }
        })
        .finally(() => {
          catchUpInFlight = false;
          if (current && pendingCatchUpRequest !== null) {
            const retry = () => {
              catchUpRetryTimer = null;
              if (!current || pendingCatchUpRequest === null) return;
              const pending = pendingCatchUpRequest;
              pendingCatchUpRequest = null;
              requestCatchUp(pending.afterSequence, pending.beforeSequence);
            };
            if (failed) {
              if (catchUpRetryTimer === null) {
                const timeout =
                  [1_000, 2_000, 5_000, 10_000][catchUpRetryAttempts] ??
                  15_000;
                catchUpRetryAttempts += 1;
                catchUpRetryTimer = window.setTimeout(retry, timeout);
              }
            } else {
              retry();
            }
          }
        });
    };
    requestCatchUpRef.current = requestCatchUp;

    const scheduleReconnect = () => {
      if (!current || reconnectTimer) return;
      realtime?.disconnect();
      realtime = null;
      realtimeRef.current = null;
      setConnectionStatus("reconnecting");
      const timeout = [1_000, 2_000, 5_000, 10_000][reconnectAttempts] ?? 15_000;
      reconnectAttempts += 1;
      reconnectTimer = window.setTimeout(() => {
        reconnectTimer = null;
        void connectRealtime();
      }, timeout);
    };

    async function connectRealtime() {
      try {
        const { ticket } = await api.socketTicket();
        if (!current) return;
        realtime = new RealtimeConversation(
          socketEndpoint(import.meta.env.VITE_API_BASE_URL || ""),
          ticket,
          conversationId,
          () => contiguousSequenceRef.current,
          {
            onStatus: (status) => {
              if (!current || activeConversationIdRef.current !== conversationId) return;
              setConnectionStatus(status);
              if (status !== "live") {
                presenceUserIdsSignatureRef.current = null;
                setOnlineUsers(0);
                cancelScheduledConversationMembersRefresh();
              }
              if (status === "live") {
                reconnectAttempts = 0;
                void refreshConversations().catch(() => undefined);
              }
            },
            onMessages: (incoming) => {
              if (current && activeConversationIdRef.current === conversationId) {
                receiveMessages(incoming);
              }
            },
            onReactionAdded: (event) => {
              if (current && activeConversationIdRef.current === conversationId) {
                applyReaction(event, true);
              }
            },
            onReactionRemoved: (event) => {
              if (current && activeConversationIdRef.current === conversationId) {
                applyReaction(event, false);
              }
            },
            onRead: (event: ReadCursorEvent) => {
              if (current && activeConversationIdRef.current === conversationId) {
                setReadCursors((cursors) => ({ ...cursors, [event.user_id]: event.sequence }));
              }
            },
            onTyping: (userId, active) => setTypingUsers((currentUsers) => {
              if (!current || activeConversationIdRef.current !== conversationId) {
                return currentUsers;
              }
              const next = new Set(currentUsers);
              if (active) next.add(userId); else next.delete(userId);
              return next;
            }),
            onPresence: (count, userIds) => {
              if (!current || activeConversationIdRef.current !== conversationId) return;
              setOnlineUsers(count);
              const signature = [...new Set(userIds)].sort().join("\u0000");
              if (presenceUserIdsSignatureRef.current !== signature) {
                presenceUserIdsSignatureRef.current = signature;
                scheduleConversationMembersRefresh(conversationId);
              }
            },
            onMembershipChanged: () => {
              if (!current || activeConversationIdRef.current !== conversationId) return;
              setMembershipVersion((value) => value + 1);
              scheduleConversationMembersRefresh(conversationId);
            },
            onConversationChanged: () => {
              if (current && activeConversationIdRef.current === conversationId) {
                void refreshConversations().catch(() => undefined);
              }
            },
            onCallStarted: (event) => {
              if (current && activeConversationIdRef.current === conversationId) {
                publishRealtimeEvent(event);
              }
            },
            onCallEnded: (event) => {
              if (current && activeConversationIdRef.current === conversationId) {
                publishRealtimeEvent(event);
              }
            },
            onAudioCallStarted: (event) => {
              if (current && activeConversationIdRef.current === conversationId) {
                publishRealtimeEvent(event);
              }
            },
            onAudioCallEnded: (event) => {
              if (current && activeConversationIdRef.current === conversationId) {
                publishRealtimeEvent(event);
              }
            },
            onCatchUpRequired: (afterSequence) =>
              requestCatchUp(afterSequence),
            onError: (message) => {
              if (current && activeConversationIdRef.current === conversationId) {
                setError(message);
              }
            },
            onReconnectRequired: scheduleReconnect
          }
        );
        realtimeRef.current = realtime;
        realtime.connect();
      } catch (reason: unknown) {
        if (current) {
          setError(errorText(reason));
          scheduleReconnect();
        }
      }
    }

    async function loadAndConnect() {
      try {
        const targeted = linkedSearchSequence;
        const start = Math.max(0, targeted ? targeted - 60 : activeLatestSequence - 100);
        contiguousSequenceRef.current = start;
        setContiguousSequence(start);
        const page = await api.messages(conversationId, start, 100);
        if (!current) return;
        mergeRetainedSenderLabels(page.included?.sender_labels);
        receiveMessages(page.data);
        setHasOlder((page.data[0]?.conversation_sequence || start + 1) > 1);

        if (realtimeDisabled) setConnectionStatus("offline");
        else await connectRealtime();
      } catch (reason: unknown) {
        if (current) {
          setConnectionStatus("offline");
          setError(errorText(reason));
        }
      } finally {
        if (current) setMessagesLoading(false);
      }
    }

    void loadAndConnect();
    return () => {
      current = false;
      requestCatchUpRef.current = () => undefined;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      if (catchUpRetryTimer) window.clearTimeout(catchUpRetryTimer);
      realtime?.disconnect();
      if (realtimeRef.current === realtime) realtimeRef.current = null;
    };
  }, [
    activeConversation?.id,
    activeConversationId,
    cancelScheduledConversationMembersRefresh,
    linkedSearchSequence,
    mergeRetainedSenderLabels,
    refreshConversationMembers,
    scheduleConversationMembersRefresh,
    session?.user.id
  ]);

  const latestSequence = messages.at(-1)?.conversation_sequence || 0;
  const readableSequence = Math.min(latestSequence, contiguousSequence);
  useEffect(() => {
    if (!activeConversationId || !isNearBottom || readableSequence <= 0 || (isMobile && mobilePane !== "messages")) return;
    let timer: number | null = null;
    const mark = () => {
      if (document.visibilityState !== "visible") return;
      if (timer) window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        const command = realtimeRef.current
          ? realtimeRef.current.markRead(readableSequence).then(() => undefined)
          : api.markRead(activeConversationId, readableSequence);
        void command.then(() => setConversations((current) => current.map((conversation) => conversation.id === activeConversationId ? { ...conversation, last_read_sequence: readableSequence, unread_count: 0 } : conversation))).catch(() => undefined);
      }, 500);
    };
    mark();
    document.addEventListener("visibilitychange", mark);
    return () => {
      if (timer) window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", mark);
    };
  }, [activeConversationId, api, isMobile, isNearBottom, mobilePane, readableSequence, setConversations]);

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
    if (!nearBottomRef.current && !forceScrollToLatestRef.current) return;
    messagesEndRef.current?.scrollIntoView({ behavior: forceScrollToLatestRef.current ? "smooth" : "auto", block: "nearest" });
    forceScrollToLatestRef.current = false;
    updateNearBottom(true);
  }, [activeConversationId, focusTarget?.conversationId, latestSequence, updateNearBottom]);

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
    const attachmentIds = new Set(input.attachment_ids || []);
    const originAttachmentEntries = [...attachmentIntentIdsRef.current]
      .filter(([, attachmentId]) => attachmentIds.has(attachmentId));
    for (const attachmentId of attachmentIds) {
      sendingAttachmentIdsRef.current.add(attachmentId);
    }
    const realtime = connectionStatus === "live" ? realtimeRef.current : null;
    let message: Message;
    try {
      message = realtime
        ? await realtime.sendMessage(input)
        : await api.sendMessage(conversationId, input);
    } catch (reason: unknown) {
      for (const attachmentId of attachmentIds) {
        sendingAttachmentIdsRef.current.delete(attachmentId);
      }
      if (activeConversationIdRef.current !== conversationId) {
        for (const [clientId] of originAttachmentEntries) {
          abandonClientAttachmentInBackground(clientId);
        }
      }
      throw reason;
    }
    for (const attachmentId of attachmentIds) {
      sendingAttachmentIdsRef.current.delete(attachmentId);
    }
    for (const [clientId, attachmentId] of originAttachmentEntries) {
      if (attachmentIntentIdsRef.current.get(clientId) === attachmentId) {
        attachmentIntentIdsRef.current.delete(clientId);
      }
    }
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
    setPendingAttachments([]);
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
    if (!pendingAttachments.every(attachmentUploadReady)) return setError("Wait for every attachment safety scan to finish or remove the file.");
    const input: SendMessageInput = {
      client_message_id: clientMessageId(),
      body,
      attachment_ids: pendingAttachments.flatMap(({ attachment }) => attachment ? [attachment.id] : []),
      reply_to_message_id: replyTo?.id || null,
      mentioned_user_ids: mentionedUserIds
    };
    setSending(true);
    setError(null);
    realtimeRef.current?.setTyping(false);
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
    const realtime = connectionStatus === "live" ? realtimeRef.current : null;
    const message = realtime
      ? await realtime.sendMessage(input)
      : await api.sendMessage(conversationId, input);
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
    realtimeRef.current?.setTyping(true);
    if (typingTimerRef.current) window.clearTimeout(typingTimerRef.current);
    typingTimerRef.current = window.setTimeout(() => realtimeRef.current?.setTyping(false), 1_500);
  }

  async function monitorAttachment(
    clientId: string,
    id: string,
    controller: AbortController
  ) {
    try {
      for (let attempt = 0; attempt < 45; attempt += 1) {
        await abortableDelay(1_000, controller.signal);
        if (cancelledAttachmentUploadsRef.current.has(clientId)) return;
        try {
          const response = await api.attachmentStatus(id, controller.signal);
          const attachment = response.data;
          if (cancelledAttachmentUploadsRef.current.has(clientId)) return;
          if (attachment.status === "ready") {
            updatePendingAttachment(clientId, { attachment, phase: "ready", error: undefined });
            return;
          }
          if (["quarantined", "scan_failed", "deleted"].includes(attachment.status)) {
            const message = `${attachment.file_name} could not be attached: ${attachment.status.replace("_", " ")}.`;
            updatePendingAttachment(clientId, { attachment, phase: "blocked", error: message });
            setError(message);
            return;
          }
        } catch (reason: unknown) {
          if (controller.signal.aborted) return;
          if (attempt === 44) {
            const message = errorText(reason);
            updatePendingAttachment(clientId, { phase: "scan_delayed", error: message });
            setError(message);
            return;
          }
        }
      }
      const message = "Attachment scanning is taking longer than expected. You can remove the file and retry later.";
      updatePendingAttachment(clientId, { phase: "scan_delayed", error: message });
      setError(message);
    } finally {
      if (attachmentUploadControllersRef.current.get(clientId) === controller) {
        attachmentUploadControllersRef.current.delete(clientId);
      }
    }
  }

  async function filesSelected(event: ChangeEvent<HTMLInputElement>) {
    const selected = [...(event.target.files || [])];
    event.target.value = "";
    if (selected.length === 0) return;
    setError(null);
    const queued = selected.map((file) => ({
      clientId: clientMessageId(),
      file,
      localName: file.name,
      phase: "hashing" as const
    }));
    setPendingAttachments((current) => [...current, ...queued]);
    await Promise.all(queued.map((item) => processAttachment(item)));
  }

  async function processAttachment(item: PendingAttachmentUpload) {
    const { clientId, file } = item;
    attachmentUploadControllersRef.current.get(clientId)?.abort();
    const controller = new AbortController();
    attachmentUploadControllersRef.current.set(clientId, controller);
    cancelledAttachmentUploadsRef.current.delete(clientId);
    let monitoring = false;
    try {
      const maxBytes = capabilities?.max_attachment_bytes;
      if (!maxBytes) throw new Error("The server did not provide an attachment size limit");
      if (file.size > maxBytes) throw new Error(`${file.name} exceeds the ${formatAttachmentLimit(maxBytes)} limit`);

      updatePendingAttachment(clientId, { phase: "hashing", error: undefined });
      const checksum = await sha256(file);
      if (cancelledAttachmentUploadsRef.current.has(clientId)) return;

      updatePendingAttachment(clientId, { phase: "requesting" });
      // Keep intent creation alive long enough to receive its server ID. If the
      // user cancels while this request is in flight, the resolved ID is
      // immediately abandoned instead of becoming an unreachable pending row.
      const intent = await api.createAttachment(file, checksum);
      attachmentIntentIdsRef.current.set(clientId, intent.data.id);
      if (attachmentCancelled(clientId, controller, cancelledAttachmentUploadsRef)) {
        abandonClientAttachmentInBackground(clientId);
        return;
      }

      updatePendingAttachment(clientId, { attachment: intent.data, phase: "uploading" });
      await uploadToPresignedTarget(intent.upload, file, controller.signal);
      if (attachmentCancelled(clientId, controller, cancelledAttachmentUploadsRef)) {
        abandonClientAttachmentInBackground(clientId);
        return;
      }

      updatePendingAttachment(clientId, { phase: "finalizing" });
      const attachment = await api.completeAttachment(intent.data.id, controller.signal);
      if (attachmentCancelled(clientId, controller, cancelledAttachmentUploadsRef)) {
        abandonClientAttachmentInBackground(clientId);
        return;
      }

      if (attachment.status === "ready") {
        updatePendingAttachment(clientId, { attachment, phase: "ready" });
        return;
      }
      if (["quarantined", "scan_failed", "deleted"].includes(attachment.status)) {
        const message = `${attachment.file_name} could not be attached: ${attachment.status.replace("_", " ")}.`;
        updatePendingAttachment(clientId, { attachment, phase: "blocked", error: message });
        setError(message);
        return;
      }
      updatePendingAttachment(clientId, { attachment, phase: "scanning" });
      monitoring = true;
      void monitorAttachment(clientId, attachment.id, controller);
    } catch (reason: unknown) {
      if (attachmentCancelled(clientId, controller, cancelledAttachmentUploadsRef)) {
        abandonClientAttachmentInBackground(clientId);
        return;
      }
      const message = errorText(reason);
      updatePendingAttachment(clientId, { phase: "retryable_error", error: message });
      setError(message);
    } finally {
      if (
        !monitoring &&
        attachmentUploadControllersRef.current.get(clientId) === controller
      ) {
        attachmentUploadControllersRef.current.delete(clientId);
      }
    }
  }

  function updatePendingAttachment(
    clientId: string,
    update: Partial<Pick<PendingAttachmentUpload, "attachment" | "phase" | "error" | "cancelRequested">>
  ) {
    setPendingAttachments((current) =>
      current.map((item) => item.clientId === clientId ? { ...item, ...update } : item)
    );
  }

  async function cancelAttachment(clientId: string) {
    cancelledAttachmentUploadsRef.current.add(clientId);
    attachmentUploadControllersRef.current.get(clientId)?.abort();
    attachmentUploadControllersRef.current.delete(clientId);
    if (!attachmentIntentIdsRef.current.has(clientId)) {
      setPendingAttachments((current) => current.filter((item) => item.clientId !== clientId));
      return;
    }

    updatePendingAttachment(clientId, {
      phase: "cancelling",
      error: undefined,
      cancelRequested: true
    });

    try {
      await abandonClientAttachment(clientId);
      setPendingAttachments((current) => current.filter((item) => item.clientId !== clientId));
    } catch {
      const message = "The file could not be removed yet. Retry, or leave it for automatic server cleanup.";
      updatePendingAttachment(clientId, {
        phase: "retryable_error",
        error: message,
        cancelRequested: true
      });
      setError(message);
    }
  }

  async function retryAttachment(clientId: string) {
    const item = pendingAttachments.find((candidate) => candidate.clientId === clientId);
    if (!item || item.phase !== "retryable_error") return;
    if (item.cancelRequested) {
      await cancelAttachment(clientId);
      return;
    }

    attachmentUploadControllersRef.current.get(clientId)?.abort();
    updatePendingAttachment(clientId, { phase: "cancelling", error: undefined });

    try {
      await abandonClientAttachment(clientId);
    } catch {
      const message = "The previous secure upload could not be removed. Retry before creating a replacement.";
      updatePendingAttachment(clientId, {
        phase: "retryable_error",
        error: message,
        cancelRequested: false
      });
      setError(message);
      return;
    }

    if (cancelledAttachmentUploadsRef.current.has(clientId)) return;
    void processAttachment({
      ...item,
      attachment: undefined,
      phase: "hashing",
      error: undefined,
      cancelRequested: false
    });
  }

  async function loadOlder() {
    if (!activeConversationId || olderLoading) return;
    const conversationId = activeConversationId;
    const requestGeneration = ++loadOlderRequestGenerationRef.current;
    const oldest = messages[0]?.conversation_sequence;
    if (!oldest || oldest <= 1) return setHasOlder(false);
    setOlderLoading(true);
    const scroll = scrollRef.current;
    const previousHeight = scroll?.scrollHeight || 0;
    try {
      const after = Math.max(0, oldest - 201);
      const page = await api.messages(conversationId, after, 200, oldest);
      if (
        requestGeneration !== loadOlderRequestGenerationRef.current ||
        activeConversationIdRef.current !== conversationId
      ) {
        return;
      }
      mergeRetainedSenderLabels(page.included?.sender_labels);
      page.data.forEach((message) => knownMessageIdsRef.current.add(message.id));
      setMessages((current) => {
        const byId = new Map([...page.data, ...current].map((message) => [message.id, message]));
        return [...byId.values()].sort((left, right) => left.conversation_sequence - right.conversation_sequence);
      });
      setHasOlder((page.data[0]?.conversation_sequence || oldest) > 1);
      window.requestAnimationFrame(() => {
        if (
          requestGeneration === loadOlderRequestGenerationRef.current &&
          activeConversationIdRef.current === conversationId &&
          scroll
        ) {
          scroll.scrollTop += scroll.scrollHeight - previousHeight;
        }
      });
    } catch (reason: unknown) {
      if (
        requestGeneration === loadOlderRequestGenerationRef.current &&
        activeConversationIdRef.current === conversationId
      ) {
        setError(errorText(reason));
      }
    } finally {
      if (
        requestGeneration === loadOlderRequestGenerationRef.current &&
        activeConversationIdRef.current === conversationId
      ) {
        setOlderLoading(false);
      }
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

  async function openAttachment(attachment: Attachment) {
    if (attachment.status !== "ready") return setError("This attachment is not available until its safety scan passes.");
    setError(null);
    try {
      const response = await api.attachmentDownload(attachment.id);
      const url = downloadUrl(response.download);
      if (!url) throw new Error("The server did not return an approved HTTPS download URL");
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (reason: unknown) {
      setError(errorText(reason));
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
  const uploading = pendingAttachments.some(attachmentUploadBusy);
  const attachmentsReady = pendingAttachments.every(attachmentUploadReady);
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
  const invitationPath = "/admin?section=people#admin-invitations";
  const peoplePath = "/admin?section=people#people-title";
  const showOnboardingSpotlight =
    showOnboarding &&
    (needsFirstTeammate || needsTeammateAccessReview || conversations.length === 0);

  function dismissOnboarding() {
    try { window.localStorage.setItem(onboardingStorageKey, "dismissed"); } catch { /* Private or constrained storage must not block dismissal. */ }
    setShowOnboarding(false);
  }

  return (
    <main className={`workspace-grid mobile-${mobilePane}`} id="main-content">
      {notice && <div className="workspace-notice" role="status">{notice}<button type="button" aria-label="Dismiss notice" onClick={() => setNotice(null)}>×</button></div>}
      <aside className="conversation-sidebar" aria-label="Conversations">
        <div className="sidebar-heading">
          <div>
            <span className="eyebrow">Messages and rooms</span>
            <h1>Inbox</h1>
            <span className="mobile-workspace-label">K-Comms <span aria-hidden="true">⌄</span></span>
          </div>
          <div className="sidebar-tools">
            <button
              className="icon-button inbox-filter-trigger"
              type="button"
              aria-label="Browse channels"
              aria-expanded={showBrowseChannels}
              onClick={() => {
                setShowBrowseChannels((visible) => !visible);
                setShowSearch(false);
                setShowDetails(false);
              }}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M4 5h16l-6.2 7.2v5.3l-3.6 1.8v-7.1L4 5Z" />
              </svg>
            </button>
            <button
              className="icon-button inbox-search-trigger"
              type="button"
              aria-label="Search messages"
              aria-expanded={showSearch}
              onClick={() => {
                setShowSearch((visible) => !visible);
                setShowBrowseChannels(false);
                setShowDetails(false);
              }}
            >
              ⌕
            </button>
            <button
              className="icon-button inbox-new-button"
              type="button"
              aria-label="Create conversation"
              aria-expanded={showCreateConversation}
              onClick={() => setShowCreateConversation((visible) => !visible)}
            >
              <span aria-hidden="true">＋</span>
              <span>New</span>
            </button>
          </div>
        </div>
        {showOnboardingSpotlight && (
          <section className="onboarding-spotlight" aria-labelledby="onboarding-spotlight-title">
            <div className="onboarding-spotlight-heading">
              <div>
                <span className="eyebrow">Quick start</span>
                <h2 id="onboarding-spotlight-title">
                  {needsFirstTeammate
                    ? "Bring in your teammate"
                    : needsTeammateAccessReview
                      ? "Reconnect your teammate"
                    : humanTeammates.length > 0
                      ? "Start your first conversation"
                      : "Your workspace is ready"}
                </h2>
              </div>
              <button
                type="button"
                aria-label="Dismiss welcome guide"
                onClick={dismissOnboarding}
              >
                ×
              </button>
            </div>
            <p>
              {needsFirstTeammate
                ? "Invite one person, then message or call from the same conversation."
                : needsTeammateAccessReview
                  ? "Review the existing inactive account before sending another invitation."
                : humanTeammates.length > 0
                  ? "Message a teammate now—there is no setup form."
                  : capabilities?.allow_public_channels === true
                    ? "Browse a room to start messaging."
                    : "An administrator needs to add you to a room or teammate conversation."}
            </p>
            <div className="onboarding-spotlight-actions">
              {needsFirstTeammate ? (
                <Link className="button primary compact" to={invitationPath}>
                  Invite your first teammate
                </Link>
              ) : needsTeammateAccessReview ? (
                <Link className="button primary compact" to={peoplePath}>
                  Manage teammate access
                </Link>
              ) : humanTeammates.length > 0 ? (
                humanTeammates.slice(0, 3).map((user) => (
                  <button
                    className="button primary compact"
                    type="button"
                    key={user.id}
                    aria-busy={directStartingUserId === user.id}
                    disabled={directStartingUserId !== null}
                    onClick={() => void startDirect(user.id)}
                  >
                    {directStartingUserId === user.id
                      ? `Opening ${participantIdentifier(user, duplicateTeammateNames)}…`
                      : `Message ${participantIdentifier(user, duplicateTeammateNames)}`}
                  </button>
                ))
              ) : capabilities?.allow_public_channels === true ? (
                <button
                  className="button primary compact"
                  type="button"
                  onClick={() => {
                    setShowBrowseChannels(true);
                    setShowCreateConversation(false);
                    setShowSearch(false);
                  }}
                >
                  Browse rooms
                </button>
              ) : null}
            </div>
            <small>Notification preferences remain available anytime under You.</small>
          </section>
        )}
        {showCreateConversation && <CreateConversationForm users={conversationUsers} allowPublicChannels={capabilities?.allow_public_channels === true} emptyDirectAction={canInviteTeammates ? <Link className="button ghost compact" to={invitationPath}>Invite your first teammate</Link> : undefined} onCancel={() => setShowCreateConversation(false)} onCreate={create} onStartDirect={startDirect} />}
        {conversations.length > 0 && <div className="conversation-filters" role="search" aria-label="Filter conversations">
          <label className="sr-only" htmlFor="conversation-filter-query">Filter conversations by title</label>
          <input id="conversation-filter-query" type="search" value={conversationQuery} onChange={(event) => setConversationQuery(event.target.value)} placeholder="Search inbox" />
          <div className="inbox-segments" role="group" aria-label="Inbox view">
            {([
              ["all", "All"],
              ["unread", "Unread"],
              ["direct", "Direct"],
              ["rooms", "Rooms"]
            ] as const).map(([value, label]) => (
              <button
                className="inbox-segment"
                type="button"
                key={value}
                aria-pressed={inboxFilter === value}
                onClick={() => setInboxFilter(value)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>}
        <nav className="conversation-list" aria-label="Conversation list">
          {conversations.length === 0 ? showOnboardingSpotlight ? <p className="empty-copy">Your conversations will appear here.</p> : <div className="conversation-zero-state"><p className="empty-copy">No conversations yet. Choose how you want to get started.</p><div className="empty-state-actions"><button className="button primary compact" type="button" onClick={() => { setShowCreateConversation(true); setShowBrowseChannels(false); setShowSearch(false); }}>Start a conversation</button><button className="button ghost compact" type="button" onClick={() => { setShowBrowseChannels(true); setShowCreateConversation(false); setShowSearch(false); }}>Browse channels</button>{canInviteTeammates && <Link className="button ghost compact" to={invitationPath}>Invite a teammate</Link>}</div></div> : filteredConversations.length === 0 ? <p className="empty-copy" role="status">No conversations match these filters.</p> : filteredConversations.map((conversation) => (
            <button
              ref={(element) => {
                if (element) conversationButtonRefs.current.set(conversation.id, element);
                else conversationButtonRefs.current.delete(conversation.id);
              }}
              type="button"
              key={conversation.id}
              className={`conversation-row ${conversation.id === activeConversationId ? "active" : ""}`}
              aria-current={conversation.id === activeConversationId ? "page" : undefined}
              onClick={() => selectConversation(conversation.id)}
            >
              <span className={`conversation-icon ${conversation.kind}`} aria-hidden="true">
                {conversation.kind === "channel"
                  ? "#"
                  : conversation.kind === "direct"
                    ? conversationInitials(conversationIdentifier(conversation))
                    : "◇"}
              </span>
              <span className="conversation-copy">
                <span className="conversation-title-line">
                  <strong>{conversationIdentifier(conversation)}</strong>
                  <time dateTime={conversation.updated_at}>{formatTime(conversation.updated_at)}</time>
                </span>
                <small>{conversation.kind === "direct" ? "Direct message" : conversation.kind === "channel" ? "Room conversation" : "Group conversation"}</small>
              </span>
              {(conversation.unread_count || 0) > 0 && <span className="unread-badge" aria-label={`${conversation.unread_count} unread messages`}>{conversation.unread_count}</span>}
            </button>
          ))}
        </nav>
      </aside>

      <section className="conversation-pane" aria-label={activeConversation ? conversationIdentifier(activeConversation) : "Messages"}>
        {activeConversation ? <>
          <header className="conversation-header"><button ref={mobileBackRef} className="mobile-back" type="button" onClick={showConversationList} aria-label="Back to conversations">←</button><div><span className="eyebrow">{activeConversation.kind} · {activeConversation.visibility}</span><h2 data-route-focus>{conversationIdentifier(activeConversation)}</h2></div><div className="conversation-header-actions"><div className="connection-summary" aria-live="polite"><span className={`status-dot ${connectionStatus}`} aria-hidden="true" /><span>{connectionLabel(connectionStatus)}</span>{onlineUsers > 0 && <small>{onlineUsers} online</small>}</div><button className="icon-button mobile-header-search" type="button" aria-label="Search messages" aria-expanded={showSearch} onClick={() => { setShowSearch((visible) => !visible); setShowBrowseChannels(false); setShowDetails(false); setShowGuestShare(false); }}><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.8" cy="10.8" r="6.4" /><path d="m15.5 15.5 4.2 4.2" /></svg></button><CallLaunchActions conversation={activeConversation} audioEnabled={capabilities?.allow_audio_calls === true && audioCallsAvailable} videoEnabled={capabilities?.allow_video_calls === true && videoCallsAvailable} />{(activeConversation.kind === "direct" || canCreateGuestLink(activeConversation)) && <button className="button ghost compact" type="button" aria-haspopup="dialog" onClick={() => { setShowGuestShare(true); setShowDetails(false); setShowSearch(false); setShowBrowseChannels(false); }}>Invite guest</button>}<button className="button ghost compact" type="button" aria-expanded={showDetails} onClick={() => { setShowDetails((visible) => !visible); setShowGuestShare(false); }}>Details</button></div></header>
          <div className="message-scroll" ref={scrollRef} aria-busy={messagesLoading} onScroll={messageScrollChanged}>
            {hasOlder && <div className="history-loader"><button className="button ghost compact" type="button" disabled={olderLoading} onClick={() => void loadOlder()}>{olderLoading ? "Loading…" : "Load older messages"}</button></div>}
            {messagesLoading && messages.length === 0 ? <div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading messages…</div> : messages.length === 0 ? <div className="empty-state"><span className="empty-mark" aria-hidden="true">✦</span><h3>Start the conversation</h3><p>Messages are durable, ordered, and replayed when you reconnect.</p></div> : <ol className="message-list">{messages.map((message) => { const replyPreview = message.reply_to_message_id ? messagesById.get(message.reply_to_message_id) : undefined; const senderName = visibleSenderIdentifier(message.sender_user_id); const replySenderName = replyPreview ? visibleSenderIdentifier(replyPreview.sender_user_id) : undefined; return <MessageItem key={message.id} message={message} currentUserId={session.user.id} senderName={senderName} replyPreview={replyPreview} replySenderName={replySenderName} seenCount={Object.entries(readCursors).filter(([userId, sequence]) => userId !== session.user.id && sequence >= message.conversation_sequence).length} focused={focusTarget?.id === message.id} onReaction={(emoji) => void toggleReaction(message, emoji)} onAttachment={(attachment) => void openAttachment(attachment)} onReply={() => { setReplyTo(message); document.getElementById("message-composer")?.focus(); }} onThread={() => setThreadTargetId(message.id)} onEdit={(body) => editMessage(message, body)} onDelete={() => deleteMessage(message)} onReport={() => { setReportError(null); setReportTarget(message); }} />; })}</ol>}
            <div ref={messagesEndRef} />
          </div>
          <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">{newMessageCount > 0 ? `${newMessageCount} new ${newMessageCount === 1 ? "message" : "messages"}.` : ""}</p>
          {!isNearBottom && <div className="new-message-jump"><button className="button primary compact" type="button" onClick={jumpToLatest}>{newMessageCount > 0 ? `${newMessageCount} new ${newMessageCount === 1 ? "message" : "messages"} · Jump to latest` : "Jump to latest"}</button></div>}
          <div className="typing-line" aria-live="polite">{activeTyping.length > 0 ? `${activeTyping.join(", ")} ${activeTyping.length === 1 ? "is" : "are"} typing…` : "\u00a0"}</div>
          <form className="composer" onSubmit={(event) => void sendMessage(event)}>
            {failedSend && <div className="failed-send" role="alert"><span>Message not sent. Your draft is safe. {failedSend.error}</span><button className="button ghost compact" type="button" disabled={sending} onClick={() => void retrySend()}>Retry</button></div>}
            {replyTo && <div className="composer-reply"><span>Replying to <strong>{replyTo.sender_user_id === session.user.id ? "yourself" : visibleSenderIdentifier(replyTo.sender_user_id) || "a message"}</strong><small>{replyTo.body}</small></span><button type="button" aria-label="Cancel reply" onClick={() => setReplyTo(null)}>×</button></div>}
            {pendingAttachments.length > 0 && <AttachmentUploadList items={pendingAttachments} onCancel={cancelAttachment} onRetry={retryAttachment} />}
            <MentionPicker members={conversationMembers} currentUserId={session.user.id} selectedUserIds={mentionedUserIds} disabled={sending} onChange={setMentionedUserIds} />
            <label className="sr-only" htmlFor="message-composer">Message</label><textarea id="message-composer" value={composer} onChange={composerChanged} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} rows={2} maxLength={65_535} placeholder={`Message ${conversationIdentifier(activeConversation)}`} disabled={sending} />
            <div className="composer-actions"><label className={`attachment-button ${sending ? "disabled" : ""}`}><input type="file" multiple disabled={sending} onChange={(event) => void filesSelected(event)} accept="image/*,text/*,application/pdf,application/zip,application/json" aria-label="Attach files" /><span aria-hidden="true">＋</span>Attach</label><span className="composer-hint">Draft saved · Enter to send · Shift+Enter for a new line</span><button className="button primary send-button" type="submit" disabled={sending || uploading || !attachmentsReady || !composer.trim()}>{sending ? "Sending…" : "Send"}<span aria-hidden="true">↗</span></button></div>
          </form>
        </> : <div className="empty-state full-height"><span className="empty-mark" aria-hidden="true">◇</span><h2>Select a conversation</h2><p>Choose a direct message, group or channel.</p></div>}
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

function conversationInitials(title: string): string {
  return title
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0]?.toLocaleUpperCase() || "")
    .join("") || "@";
}

function newSenderLabelRefreshBackoff(
  conversationId: string | null
): SenderLabelRefreshBackoff {
  return {
    conversationId,
    candidateSignature: null,
    resultSignature: null,
    delayIndex: 0,
    nextAttemptAt: 0
  };
}

function senderLabelRefreshAllowed(
  backoffRef: { current: SenderLabelRefreshBackoff },
  conversationId: string,
  messageIds: string[]
): boolean {
  const candidateSignature = JSON.stringify([...messageIds].sort());
  let current = backoffRef.current;
  if (
    current.conversationId !== conversationId ||
    current.candidateSignature !== candidateSignature
  ) {
    current = {
      ...newSenderLabelRefreshBackoff(conversationId),
      candidateSignature
    };
    backoffRef.current = current;
  }
  return (
    document.visibilityState === "visible" &&
    Date.now() >= current.nextAttemptAt
  );
}

function recordSenderLabelRefresh(
  backoffRef: { current: SenderLabelRefreshBackoff },
  conversationId: string,
  messageIds: string[],
  labels: RetainedSenderLabel[]
): void {
  const candidateSignature = JSON.stringify([...messageIds].sort());
  const resultSignature = JSON.stringify(
    [...labels]
      .sort((left, right) => left.id.localeCompare(right.id))
      .map(({ id, display_name, redacted }) => [id, display_name, redacted])
  );
  const current = backoffRef.current;
  if (
    current.conversationId !== conversationId ||
    current.candidateSignature !== candidateSignature
  ) {
    return;
  }
  const changed =
    current.resultSignature !== null &&
    current.resultSignature !== resultSignature;
  const delayIndex =
    current.resultSignature === null || changed
      ? 0
      : Math.min(
          current.delayIndex + 1,
          senderLabelRefreshDelaysMs.length - 1
        );
  const delayMs =
    senderLabelRefreshDelaysMs[delayIndex] ??
    300_000;
  backoffRef.current = {
    ...current,
    resultSignature,
    delayIndex,
    nextAttemptAt: Date.now() + delayMs
  };
}

function connectionLabel(status: ConnectionStatus): string {
  if (status === "live") return "Live";
  if (status === "connecting") return "Connecting";
  if (status === "reconnecting") return "Reconnecting";
  return "Offline";
}

function formatAttachmentLimit(value: number): string {
  return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(value % 1_000_000 === 0 ? 0 : 1)} MB` : `${Math.ceil(value / 1_000)} KB`;
}

function abortableDelay(milliseconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new DOMException("The upload was cancelled", "AbortError"));
      return;
    }
    const timer = window.setTimeout(resolve, milliseconds);
    signal.addEventListener("abort", () => {
      window.clearTimeout(timer);
      reject(new DOMException("The upload was cancelled", "AbortError"));
    }, { once: true });
  });
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

function attachmentCancelled(
  clientId: string,
  controller: AbortController,
  cancelled: { current: Set<string> }
): boolean {
  return controller.signal.aborted || cancelled.current.has(clientId);
}

function safeUuid(value: string | null): string | null {
  return value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

function safePositiveInteger(value: string | null): number | null {
  if (!value || !/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function safeCallKind(value: string | null): "audio" | "video" | null {
  return value === "audio" || value === "video" ? value : null;
}

function readOnboardingPreference(storageKey: string): boolean {
  try { return window.localStorage.getItem(storageKey) !== "dismissed"; } catch { return true; }
}
