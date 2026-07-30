import type {
  Conversation,
  Message,
  ReactionEvent
} from "../../types";

export interface ConversationActivity {
  latest: number;
  hasMessageFromOther: boolean;
}

export function collectConversationActivity(
  incoming: Message[],
  currentUserId?: string
): Map<string, ConversationActivity> {
  const activityByConversation = new Map<string, ConversationActivity>();
  for (const message of incoming) {
    const current = activityByConversation.get(message.conversation_id);
    activityByConversation.set(message.conversation_id, {
      latest: Math.max(
        current?.latest || 0,
        message.conversation_sequence
      ),
      hasMessageFromOther:
        current?.hasMessageFromOther === true ||
        message.sender_user_id !== currentUserId
    });
  }
  return activityByConversation;
}

export function updateConversationActivity(
  conversations: Conversation[],
  activityByConversation: ReadonlyMap<string, ConversationActivity>,
  activeConversationId: string | null,
  visibleAndNearBottom: boolean
): Conversation[] {
  return conversations.map((conversation) => {
    const activity = activityByConversation.get(conversation.id);
    if (!activity) return conversation;
    const latestSequence = Math.max(
      conversation.latest_sequence,
      activity.latest
    );
    const shouldRemainUnread =
      conversation.id !== activeConversationId || !visibleAndNearBottom;
    return {
      ...conversation,
      latest_sequence: latestSequence,
      unread_count:
        shouldRemainUnread && activity.hasMessageFromOther
          ? Math.max(
              conversation.unread_count || 0,
              latestSequence - (conversation.last_read_sequence || 0)
            )
          : conversation.unread_count
    };
  });
}

export function mergeConversationMessages(
  current: Message[],
  incoming: Message[]
): Message[] {
  const byId = new Map(current.map((message) => [message.id, message]));
  for (const message of incoming) {
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
  }
  return [...byId.values()].sort(
    (left, right) =>
      left.conversation_sequence - right.conversation_sequence
  );
}

export function applyMessageReaction(
  messages: Message[],
  event: ReactionEvent,
  add: boolean
): Message[] {
  return messages.map((message) => {
    if (message.id !== event.message_id) return message;
    const without = message.reactions.filter(
      (reaction) =>
        !(
          reaction.user_id === event.user_id &&
          reaction.emoji === event.emoji
        )
    );
    return {
      ...message,
      reactions: add
        ? [
            ...without,
            { user_id: event.user_id, emoji: event.emoji }
          ]
        : without
    };
  });
}

export function advanceContiguousSequence(
  current: number,
  futureSequences: Set<number>,
  incoming: Message[]
): number {
  for (const message of incoming) {
    if (message.conversation_sequence > current) {
      futureSequences.add(message.conversation_sequence);
    }
  }
  let next = current;
  while (futureSequences.delete(next + 1)) next += 1;
  return next;
}
