import { useCallback, useEffect, useRef, useState } from "react";
import { errorText } from "../../lib/format";
import type {
  ConversationMembership,
  RetainedSenderLabel
} from "../../types";
import type { GuestRoomApi } from "./roomApi";
import {
  newSenderLabelRefreshBackoff,
  recordSenderLabelRefresh,
  senderLabelRefreshAllowed,
  type SenderLabelRefreshBackoff
} from "./guestSenderLabelRefresh";

interface UseGuestParticipantsOptions {
  api: GuestRoomApi;
  conversationId: string;
  mergeRetainedSenderLabels: (labels: RetainedSenderLabel[]) => void;
  setError: (error: string) => void;
  visibleMessageAuthorsRef: {
    current: Array<{ senderUserId: string; messageId: string }>;
  };
}

export function useGuestParticipants({
  api,
  conversationId,
  mergeRetainedSenderLabels,
  setError,
  visibleMessageAuthorsRef
}: UseGuestParticipantsOptions) {
  const [members, setMembers] = useState<ConversationMembership[]>([]);
  const membersRequestGenerationRef = useRef(0);
  const membersReloadInFlightRef = useRef(false);
  const membersReloadPendingRef = useRef(false);
  const scheduleMembersReloadRef = useRef<() => void>(() => undefined);
  const membersReloadTimerRef = useRef<number | null>(null);
  const memberIdsSignatureRef = useRef<string | null>(null);
  const senderLabelRefreshBackoffRef = useRef<SenderLabelRefreshBackoff>(
    newSenderLabelRefreshBackoff(conversationId)
  );

  const reloadMembers = useCallback(async (
    errorTarget: "shell" | "initial" = "shell"
  ): Promise<void> => {
    if (membersReloadInFlightRef.current) {
      membersReloadPendingRef.current = true;
      membersRequestGenerationRef.current += 1;
      return;
    }
    membersReloadInFlightRef.current = true;
    const requestGeneration = ++membersRequestGenerationRef.current;
    try {
      const nextMembers = await api.conversationMembers();
      if (requestGeneration !== membersRequestGenerationRef.current) return;
      setMembers(nextMembers);
      const nextSignature = nextMembers
        .map(({ user }) => user.id)
        .sort()
        .join("\u0000");
      const previousSignature = memberIdsSignatureRef.current;
      memberIdsSignatureRef.current = nextSignature;
      if (previousSignature !== null) {
        const activeUserIds = new Set(nextMembers.map(({ user }) => user.id));
        const departedAuthorMessageIds = visibleMessageAuthorsRef.current
          .filter(({ senderUserId }) => !activeUserIds.has(senderUserId))
          .map(({ messageId }) => messageId);
        if (departedAuthorMessageIds.length > 0) {
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
              departedAuthorMessageIds
            );
            if (requestGeneration === membersRequestGenerationRef.current) {
              mergeRetainedSenderLabels(labels);
              recordSenderLabelRefresh(
                senderLabelRefreshBackoffRef,
                conversationId,
                departedAuthorMessageIds,
                labels
              );
            }
          } catch (reason: unknown) {
            if (requestGeneration === membersRequestGenerationRef.current) {
              setError(errorText(reason));
            }
          }
        }
      }
    } catch (reason: unknown) {
      if (requestGeneration !== membersRequestGenerationRef.current) return;
      if (errorTarget === "initial") throw reason;
      setError(errorText(reason));
    } finally {
      membersReloadInFlightRef.current = false;
      if (membersReloadPendingRef.current) {
        membersReloadPendingRef.current = false;
        scheduleMembersReloadRef.current();
      }
    }
  }, [
    api,
    conversationId,
    mergeRetainedSenderLabels,
    setError,
    visibleMessageAuthorsRef
  ]);

  const scheduleMembersReload = useCallback(() => {
    if (membersReloadTimerRef.current !== null) return;
    membersReloadTimerRef.current = window.setTimeout(() => {
      membersReloadTimerRef.current = null;
      void reloadMembers();
    }, 0);
  }, [reloadMembers]);
  scheduleMembersReloadRef.current = scheduleMembersReload;

  useEffect(() => {
    memberIdsSignatureRef.current = null;
    senderLabelRefreshBackoffRef.current =
      newSenderLabelRefreshBackoff(conversationId);
  }, [conversationId]);

  useEffect(() => {
    const reconciliationTimer = window.setInterval(
      scheduleMembersReload,
      30_000
    );
    return () => window.clearInterval(reconciliationTimer);
  }, [conversationId, scheduleMembersReload]);

  useEffect(() => () => {
    if (membersReloadTimerRef.current !== null) {
      window.clearTimeout(membersReloadTimerRef.current);
      membersReloadTimerRef.current = null;
    }
    membersReloadPendingRef.current = false;
    membersRequestGenerationRef.current += 1;
  }, [conversationId]);

  return {
    members,
    reloadMembers,
    scheduleMembersReload
  };
}
