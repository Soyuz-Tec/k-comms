import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { ApiClient } from "../../api";
import {
  duplicateParticipantNames,
  mergeRetainedSenderLabelMaps,
  participantIdentifier,
  retainedSenderLabelMap,
  resolveVisibleSenderIdentity,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import type {
  ConversationMembership,
  Message,
  RetainedSenderLabel,
  User
} from "../../types";

const REFRESH_DELAYS_MS = [30_000, 60_000, 120_000, 300_000] as const;

export function useThreadSenderIdentities({
  api,
  conversationId,
  currentUserId,
  members,
  replies,
  retainedSenderLabels,
  root,
  targetMessageId,
  users
}: {
  api: ApiClient;
  conversationId: string;
  currentUserId: string;
  members: ConversationMembership[];
  replies: Message[];
  retainedSenderLabels?: ReadonlyMap<string, RetainedSenderLabel>;
  root: Message | null;
  targetMessageId: string;
  users: User[];
}) {
  const [threadLabelsById, setThreadLabelsById] = useState(
    () => new Map<string, RetainedSenderLabel>()
  );
  const threadLabelsByIdRef = useRef(threadLabelsById);
  const [knownMemberLabelsById, setKnownMemberLabelsById] = useState(
    () => new Map<string, ParticipantIdentity>()
  );
  const activeThreadKeyRef = useRef(
    `${conversationId}:${targetMessageId}`
  );
  activeThreadKeyRef.current = `${conversationId}:${targetMessageId}`;
  const refreshInFlightRef = useRef(false);
  const refreshGenerationRef = useRef(0);
  const senderMessageIdsRef = useRef<{
    threadKey: string;
    messageIds: string[];
  }>({
    threadKey: `${conversationId}:${targetMessageId}`,
    messageIds: []
  });

  const usersById = useMemo(
    () => new Map(users.map((user) => [user.id, user])),
    [users]
  );
  const activeMembersById = useMemo(
    () => new Map(members.map(({ user }) => [user.id, user])),
    [members]
  );
  const effectiveLabelsById = useMemo(
    () =>
      mergeRetainedSenderLabelMaps(
        new Map(retainedSenderLabels || []),
        [...threadLabelsById.values()]
      ),
    [retainedSenderLabels, threadLabelsById]
  );
  const visibleSenderIdentities = useMemo(() => {
    const identitiesById = new Map<string, ParticipantIdentity>();
    for (const message of root ? [root, ...replies] : replies) {
      const identity = resolveVisibleSenderIdentity(
        message.sender_user_id,
        activeMembersById,
        effectiveLabelsById,
        [usersById, knownMemberLabelsById]
      );
      if (identity) identitiesById.set(identity.id, identity);
    }
    return identitiesById;
  }, [
    activeMembersById,
    effectiveLabelsById,
    knownMemberLabelsById,
    replies,
    root,
    usersById
  ]);
  const duplicateVisibleSenderNames = useMemo(
    () => duplicateParticipantNames(visibleSenderIdentities.values()),
    [visibleSenderIdentities]
  );

  useEffect(() => {
    threadLabelsByIdRef.current = threadLabelsById;
  }, [threadLabelsById]);

  useEffect(() => {
    setKnownMemberLabelsById(
      new Map(members.map(({ user }) => [user.id, user]))
    );
  }, [conversationId, targetMessageId]);

  useEffect(() => {
    setKnownMemberLabelsById((current) => {
      const next = new Map(current);
      for (const { user } of members) next.set(user.id, user);
      return next;
    });
  }, [members]);

  useEffect(() => {
    const messageIdBySender = new Map<string, string>();
    for (const message of root ? [root, ...replies] : replies) {
      if (!messageIdBySender.has(message.sender_user_id)) {
        messageIdBySender.set(message.sender_user_id, message.id);
      }
    }
    senderMessageIdsRef.current = {
      threadKey: `${conversationId}:${targetMessageId}`,
      messageIds: [...messageIdBySender.values()]
    };
  }, [conversationId, replies, root, targetMessageId]);

  useEffect(() => {
    const threadKey = `${conversationId}:${targetMessageId}`;
    const refreshGeneration = ++refreshGenerationRef.current;
    let current = true;
    let timeout: number | undefined;
    let backoffIndex = 0;

    const scheduleRefresh = () => {
      if (!current || document.hidden) return;
      if (timeout !== undefined) window.clearTimeout(timeout);
      timeout = window.setTimeout(() => {
        timeout = undefined;
        void refreshSenderLabels();
      }, REFRESH_DELAYS_MS[backoffIndex]);
    };

    const refreshSenderLabels = async () => {
      if (document.hidden) return;
      const snapshot = senderMessageIdsRef.current;
      if (
        snapshot.threadKey !== threadKey ||
        snapshot.messageIds.length === 0
      ) {
        return;
      }
      if (refreshInFlightRef.current) {
        scheduleRefresh();
        return;
      }
      refreshInFlightRef.current = true;
      let labelsChanged = false;
      try {
        const labels = await api.messageSenderLabels(
          conversationId,
          snapshot.messageIds
        );
        if (
          !current ||
          refreshGenerationRef.current !== refreshGeneration ||
          activeThreadKeyRef.current !== threadKey
        ) {
          return;
        }
        if (labels.length > 0) {
          const existing = threadLabelsByIdRef.current;
          const merged = mergeRetainedSenderLabelMaps(existing, labels);
          labelsChanged = !retainedSenderLabelMapsEqual(existing, merged);
          if (labelsChanged) {
            threadLabelsByIdRef.current = merged;
            setThreadLabelsById(merged);
          }
        }
      } catch {
        // Best-effort reconciliation retries with bounded backoff.
      } finally {
        refreshInFlightRef.current = false;
        if (
          current &&
          refreshGenerationRef.current === refreshGeneration &&
          activeThreadKeyRef.current === threadKey
        ) {
          backoffIndex = labelsChanged
            ? 0
            : Math.min(
                backoffIndex + 1,
                REFRESH_DELAYS_MS.length - 1
              );
          scheduleRefresh();
        }
      }
    };

    const visibilityChanged = () => {
      if (!current) return;
      if (document.hidden) {
        if (timeout !== undefined) window.clearTimeout(timeout);
        timeout = undefined;
        return;
      }
      backoffIndex = 0;
      scheduleRefresh();
    };

    document.addEventListener("visibilitychange", visibilityChanged);
    scheduleRefresh();
    return () => {
      current = false;
      refreshGenerationRef.current += 1;
      if (timeout !== undefined) window.clearTimeout(timeout);
      document.removeEventListener("visibilitychange", visibilityChanged);
    };
  }, [api, conversationId, replies, root, targetMessageId]);

  const resetSenderLabels = useCallback(
    (labels?: RetainedSenderLabel[]) => {
      const next = retainedSenderLabelMap(labels);
      threadLabelsByIdRef.current = next;
      setThreadLabelsById(next);
    },
    []
  );

  const mergeSenderLabels = useCallback(
    (labels?: RetainedSenderLabel[]) => {
      setThreadLabelsById((current) => {
        const next = mergeRetainedSenderLabelMaps(current, labels);
        threadLabelsByIdRef.current = next;
        return next;
      });
    },
    []
  );

  const senderIdentifier = useCallback(
    (userId: string): string => {
      const identity = visibleSenderIdentities.get(userId);
      const resolvedIdentifier = identity
        ? participantIdentifier(identity, duplicateVisibleSenderNames)
        : "Unknown user";
      return userId === currentUserId
        ? `${resolvedIdentifier} (you)`
        : resolvedIdentifier;
    },
    [
      currentUserId,
      duplicateVisibleSenderNames,
      visibleSenderIdentities
    ]
  );

  return {
    mergeSenderLabels,
    resetSenderLabels,
    senderIdentifier
  };
}

function retainedSenderLabelMapsEqual(
  left: ReadonlyMap<string, RetainedSenderLabel>,
  right: ReadonlyMap<string, RetainedSenderLabel>
): boolean {
  if (left.size !== right.size) return false;
  for (const [id, label] of left) {
    const candidate = right.get(id);
    if (
      !candidate ||
      candidate.display_name !== label.display_name ||
      candidate.redacted !== label.redacted
    ) {
      return false;
    }
  }
  return true;
}
