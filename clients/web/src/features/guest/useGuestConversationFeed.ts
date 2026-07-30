import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type Dispatch,
  type SetStateAction
} from "react";
import { errorText } from "../../lib/format";
import type {
  Message,
  ReactionEvent,
  RetainedSenderLabel
} from "../../types";
import { loadGuestMessageCatchUp } from "./guestMessageCatchUp";
import type { GuestRoomApi } from "./roomApi";

type PendingGuestCatchUp = {
  afterSequence: number;
  throughSequence?: number;
  announce: boolean;
};

interface UseGuestConversationFeedOptions {
  api: GuestRoomApi;
  conversationId: string;
  currentUserId: string;
  mergeRetainedSenderLabels: (labels: RetainedSenderLabel[]) => void;
  nearBottomRef: { current: boolean };
  scrollRequestRef: { current: ScrollBehavior | null };
  setError: Dispatch<SetStateAction<string>>;
  setNewMessageCount: Dispatch<SetStateAction<number>>;
}

export function useGuestConversationFeed({
  api,
  conversationId,
  currentUserId,
  mergeRetainedSenderLabels,
  nearBottomRef,
  scrollRequestRef,
  setError,
  setNewMessageCount
}: UseGuestConversationFeedOptions) {
  const [messages, setMessages] = useState<Message[]>([]);
  const latestSequenceRef = useRef(0);
  const knownMessageIdsRef = useRef(new Set<string>());
  const catchUpInFlightRef = useRef(false);
  const catchUpRetryTimerRef = useRef<number | null>(null);
  const catchUpRetryAttemptsRef = useRef(0);
  const catchUpLifecycleGenerationRef = useRef(0);
  const catchUpErrorRef = useRef<string | null>(null);
  const pendingCatchUpRef = useRef<PendingGuestCatchUp | null>(null);
  const requestCatchUpRef = useRef<(
    afterSequence: number,
    throughSequence?: number,
    announce?: boolean
  ) => void>(() => undefined);

  const mergeMessages = useCallback((
    incoming: Message[],
    options: {
      announce?: boolean;
      forceScroll?: boolean;
      behavior?: ScrollBehavior;
    } = {}
  ) => {
    if (incoming.length === 0) return;
    const newMessages = incoming.filter(({ id }) => !knownMessageIdsRef.current.has(id));
    for (const message of incoming) knownMessageIdsRef.current.add(message.id);

    if (newMessages.length > 0) {
      const ownMessage = newMessages.some(
        ({ sender_user_id: senderUserId }) => senderUserId === currentUserId
      );
      if (options.forceScroll || ownMessage || nearBottomRef.current) {
        scrollRequestRef.current = options.behavior ?? "auto";
        setNewMessageCount(0);
      } else if (options.announce !== false) {
        setNewMessageCount((count) => count + newMessages.length);
      }
    }

    setMessages((current) => {
      const byId = new Map(current.map((message) => [message.id, message]));
      for (const message of incoming) byId.set(message.id, message);
      const next = [...byId.values()].sort(
        (left, right) => left.conversation_sequence - right.conversation_sequence
      );
      latestSequenceRef.current = next.at(-1)?.conversation_sequence || 0;
      return next;
    });
  }, [currentUserId, nearBottomRef, scrollRequestRef, setNewMessageCount]);

  const requestCatchUp = useCallback((
    afterSequence: number,
    throughSequence?: number,
    announce = true
  ) => {
    const pending = pendingCatchUpRef.current;
    pendingCatchUpRef.current = pending
      ? {
          afterSequence: Math.min(pending.afterSequence, afterSequence),
          throughSequence:
            pending.throughSequence === undefined || throughSequence === undefined
              ? undefined
              : Math.max(pending.throughSequence, throughSequence),
          announce: pending.announce || announce
        }
      : { afterSequence, throughSequence, announce };
    if (catchUpInFlightRef.current) return;
    const lifecycleGeneration = catchUpLifecycleGenerationRef.current;
    catchUpInFlightRef.current = true;
    let failed = false;
    let requestInFlight: PendingGuestCatchUp | null = null;

    const drain = async () => {
      while (pendingCatchUpRef.current) {
        const requested = pendingCatchUpRef.current;
        requestInFlight = requested;
        pendingCatchUpRef.current = null;
        const nextMessages = await loadGuestMessageCatchUp(
          api,
          requested.afterSequence,
          mergeRetainedSenderLabels,
          requested.throughSequence
        );
        if (catchUpLifecycleGenerationRef.current !== lifecycleGeneration) return;
        mergeMessages(nextMessages, {
          announce: requested.announce,
          behavior: requested.announce ? "smooth" : "auto"
        });
        requestInFlight = null;
        catchUpRetryAttemptsRef.current = 0;
        if (catchUpErrorRef.current) {
          const recoveredError = catchUpErrorRef.current;
          catchUpErrorRef.current = null;
          setError((current) => current === recoveredError ? "" : current);
        }
      }
    };

    void drain()
      .catch((reason: unknown) => {
        if (catchUpLifecycleGenerationRef.current !== lifecycleGeneration) return;
        failed = true;
        if (requestInFlight) {
          const pendingRequest = pendingCatchUpRef.current;
          pendingCatchUpRef.current = pendingRequest
            ? {
                afterSequence: Math.min(
                  requestInFlight.afterSequence,
                  pendingRequest.afterSequence
                ),
                throughSequence:
                  requestInFlight.throughSequence === undefined ||
                  pendingRequest.throughSequence === undefined
                    ? undefined
                    : Math.max(
                        requestInFlight.throughSequence,
                        pendingRequest.throughSequence
                      ),
                announce: requestInFlight.announce || pendingRequest.announce
              }
            : requestInFlight;
        }
        const message = errorText(reason);
        catchUpErrorRef.current = message;
        setError(message);
      })
      .finally(() => {
        if (catchUpLifecycleGenerationRef.current !== lifecycleGeneration) return;
        catchUpInFlightRef.current = false;
        const pendingRequest = pendingCatchUpRef.current;
        if (pendingRequest) {
          const retry = () => {
            if (catchUpLifecycleGenerationRef.current !== lifecycleGeneration) return;
            catchUpRetryTimerRef.current = null;
            const request = pendingCatchUpRef.current;
            if (!request) return;
            pendingCatchUpRef.current = null;
            requestCatchUpRef.current(
              request.afterSequence,
              request.throughSequence,
              request.announce
            );
          };
          if (failed) {
            if (catchUpRetryTimerRef.current === null) {
              const attempts = catchUpRetryAttemptsRef.current;
              catchUpRetryAttemptsRef.current += 1;
              catchUpRetryTimerRef.current = window.setTimeout(
                retry,
                [1_000, 2_000, 5_000, 10_000][attempts] ?? 15_000
              );
            }
          } else {
            retry();
          }
        }
      });
  }, [api, mergeMessages, mergeRetainedSenderLabels, setError]);

  const applyReaction = useCallback((event: ReactionEvent, add: boolean) => {
    setMessages((current) => current.map((message) => {
      if (message.id !== event.message_id) return message;
      const reactions = message.reactions.filter(
        (reaction) => !(reaction.user_id === event.user_id && reaction.emoji === event.emoji)
      );
      return {
        ...message,
        reactions: add
          ? [...reactions, { user_id: event.user_id, emoji: event.emoji }]
          : reactions
      };
    }));
  }, []);

  useEffect(() => {
    catchUpLifecycleGenerationRef.current += 1;
    requestCatchUpRef.current = requestCatchUp;
    return () => {
      catchUpLifecycleGenerationRef.current += 1;
      pendingCatchUpRef.current = null;
      catchUpInFlightRef.current = false;
      if (catchUpRetryTimerRef.current !== null) {
        window.clearTimeout(catchUpRetryTimerRef.current);
        catchUpRetryTimerRef.current = null;
      }
      catchUpRetryAttemptsRef.current = 0;
      catchUpErrorRef.current = null;
      requestCatchUpRef.current = () => undefined;
    };
  }, [conversationId, requestCatchUp]);

  return {
    applyReaction,
    latestSequenceRef,
    mergeMessages,
    messages,
    requestCatchUp
  };
}
