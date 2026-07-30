import { useCallback, useEffect, useRef, useState } from "react";
import type { ApiClient } from "../../api";
import { errorText } from "../../lib/format";
import {
  mergeRetainedSenderLabelMaps,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import type {
  ConversationMembership,
  Message,
  RetainedSenderLabel
} from "../../types";
import {
  newSenderLabelRefreshBackoff,
  recordSenderLabelRefresh,
  senderLabelRefreshAllowed,
  type SenderLabelRefreshBackoff
} from "./chatSupport";

interface UseConversationMembersOptions {
  api: ApiClient;
  activeConversationId: string | null;
  setError: (error: string | null) => void;
}

export function useConversationMembers({
  api,
  activeConversationId,
  setError
}: UseConversationMembersOptions) {
  const [members, setMembers] = useState<ConversationMembership[]>([]);
  const [memberIdentities, setMemberIdentities] = useState<{
    conversationId: string | null;
    usersById: Map<string, ParticipantIdentity>;
  }>(() => ({ conversationId: null, usersById: new Map() }));
  const [retainedSenderLabels, setRetainedSenderLabels] = useState(
    () => new Map<string, RetainedSenderLabel>()
  );
  const activeConversationIdRef = useRef(activeConversationId);
  activeConversationIdRef.current = activeConversationId;
  const requestGenerationRef = useRef(0);
  const inFlightRef = useRef<{
    conversationId: string;
    token: symbol;
  } | null>(null);
  const pendingRef = useRef<string | null>(null);
  const scheduleRefreshRef = useRef<(conversationId: string) => void>(
    () => undefined
  );
  const reloadTimerRef = useRef<{
    conversationId: string;
    timer: number;
  } | null>(null);
  const memberIdsSignatureRef = useRef<{
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

  const mergeRetainedSenderLabels = useCallback(
    (incoming: RetainedSenderLabel[] | undefined) => {
      if (!incoming || incoming.length === 0) return;
      setRetainedSenderLabels((current) =>
        mergeRetainedSenderLabelMaps(current, incoming)
      );
    },
    []
  );

  const refresh = useCallback(
    async (
      conversationId: string,
      clearCurrent = false
    ): Promise<void> => {
      if (inFlightRef.current?.conversationId === conversationId) {
        pendingRef.current = conversationId;
        requestGenerationRef.current += 1;
        return;
      }
      const requestToken = Symbol(conversationId);
      inFlightRef.current = { conversationId, token: requestToken };
      const requestGeneration = ++requestGenerationRef.current;
      if (clearCurrent) {
        setMembers([]);
        setMemberIdentities({
          conversationId,
          usersById: new Map()
        });
      }
      try {
        const incoming = await api.conversationMembers(conversationId);
        if (
          requestGeneration !== requestGenerationRef.current ||
          activeConversationIdRef.current !== conversationId
        ) {
          return;
        }
        setMembers(incoming);
        setMemberIdentities((current) => {
          const usersById =
            current.conversationId === conversationId
              ? new Map(current.usersById)
              : new Map<string, ParticipantIdentity>();
          for (const { user } of incoming) usersById.set(user.id, user);
          return { conversationId, usersById };
        });
        const memberIdsSignature = incoming
          .map(({ user }) => user.id)
          .sort()
          .join("\u0000");
        const previousSignature = memberIdsSignatureRef.current;
        memberIdsSignatureRef.current = {
          conversationId,
          signature: memberIdsSignature
        };
        if (previousSignature?.conversationId !== conversationId) return;

        const visibleAuthors = visibleMessageAuthorsRef.current;
        const activeUserIds = new Set(incoming.map(({ user }) => user.id));
        const departedAuthorMessageIds =
          visibleAuthors?.conversationId === conversationId
            ? visibleAuthors.authors
                .filter(({ senderUserId }) => !activeUserIds.has(senderUserId))
                .map(({ messageId }) => messageId)
            : [];
        if (departedAuthorMessageIds.length === 0) return;
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
            requestGeneration === requestGenerationRef.current &&
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
            requestGeneration === requestGenerationRef.current &&
            activeConversationIdRef.current === conversationId
          ) {
            setError(errorText(reason));
          }
        }
      } catch (reason: unknown) {
        if (
          requestGeneration === requestGenerationRef.current &&
          activeConversationIdRef.current === conversationId
        ) {
          setError(errorText(reason));
        }
      } finally {
        if (inFlightRef.current?.token === requestToken) {
          inFlightRef.current = null;
          if (
            pendingRef.current === conversationId &&
            activeConversationIdRef.current === conversationId
          ) {
            pendingRef.current = null;
            scheduleRefreshRef.current(conversationId);
          }
        }
      }
    },
    [api, mergeRetainedSenderLabels, setError]
  );

  const cancelScheduledRefresh = useCallback(() => {
    if (reloadTimerRef.current === null) return;
    window.clearTimeout(reloadTimerRef.current.timer);
    reloadTimerRef.current = null;
  }, []);

  const scheduleRefresh = useCallback(
    (conversationId: string) => {
      const scheduled = reloadTimerRef.current;
      if (scheduled?.conversationId === conversationId) return;
      if (scheduled) window.clearTimeout(scheduled.timer);
      const timer = window.setTimeout(() => {
        if (reloadTimerRef.current?.timer !== timer) return;
        reloadTimerRef.current = null;
        if (activeConversationIdRef.current === conversationId) {
          void refresh(conversationId);
        }
      }, 0);
      reloadTimerRef.current = { conversationId, timer };
    },
    [refresh]
  );
  scheduleRefreshRef.current = scheduleRefresh;

  const notePresence = useCallback(
    (userIds: string[]) => {
      if (!activeConversationIdRef.current) return;
      const signature = [...new Set(userIds)].sort().join("\u0000");
      if (presenceUserIdsSignatureRef.current === signature) return;
      presenceUserIdsSignatureRef.current = signature;
      scheduleRefresh(activeConversationIdRef.current);
    },
    [scheduleRefresh]
  );

  const noteRealtimeDisconnected = useCallback(() => {
    presenceUserIdsSignatureRef.current = null;
    cancelScheduledRefresh();
  }, [cancelScheduledRefresh]);

  const trackVisibleMessages = useCallback((messages: Message[]) => {
    const authorMessageIds = new Map<string, string>();
    for (const message of messages) {
      if (!authorMessageIds.has(message.sender_user_id)) {
        authorMessageIds.set(message.sender_user_id, message.id);
      }
    }
    visibleMessageAuthorsRef.current =
      activeConversationId && authorMessageIds.size > 0
        ? {
            conversationId: activeConversationId,
            authors: [...authorMessageIds]
              .map(([senderUserId, messageId]) => ({
                senderUserId,
                messageId
              }))
              .sort((left, right) =>
                left.senderUserId.localeCompare(right.senderUserId)
              )
          }
        : null;
  }, [activeConversationId]);

  useEffect(() => {
    cancelScheduledRefresh();
    presenceUserIdsSignatureRef.current = null;
    memberIdsSignatureRef.current = null;
    senderLabelRefreshBackoffRef.current =
      newSenderLabelRefreshBackoff(activeConversationId);
    pendingRef.current = null;
    inFlightRef.current = null;
    setRetainedSenderLabels(new Map());
    if (!activeConversationId) {
      requestGenerationRef.current += 1;
      setMembers([]);
      setMemberIdentities({
        conversationId: null,
        usersById: new Map()
      });
      return;
    }
    const conversationId = activeConversationId;
    void refresh(conversationId, true);
    const reconciliationTimer = window.setInterval(
      () => scheduleRefresh(conversationId),
      30_000
    );
    return () => {
      window.clearInterval(reconciliationTimer);
      cancelScheduledRefresh();
      presenceUserIdsSignatureRef.current = null;
      memberIdsSignatureRef.current = null;
      pendingRef.current = null;
      inFlightRef.current = null;
      requestGenerationRef.current += 1;
    };
  }, [
    activeConversationId,
    cancelScheduledRefresh,
    refresh,
    scheduleRefresh
  ]);

  const memberUsersById =
    memberIdentities.conversationId === activeConversationId
      ? memberIdentities.usersById
      : new Map<string, ParticipantIdentity>();

  return {
    members,
    memberUsersById,
    retainedSenderLabels,
    mergeRetainedSenderLabels,
    scheduleRefresh,
    cancelScheduledRefresh,
    notePresence,
    noteRealtimeDisconnected,
    trackVisibleMessages
  };
}
