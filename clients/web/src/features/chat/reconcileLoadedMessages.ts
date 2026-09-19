import type { ApiClient } from "../../api";
import type { Message, RetainedSenderLabel } from "../../types";
import { loadConversationCatchUp } from "./conversationFeedCatchUp";

/** Refresh creation-ordered history without treating its cursor as a mutation cursor. */
export async function readLoadedMessages(
  api: ApiClient,
  conversationId: string,
  snapshot: readonly Message[],
  current: () => boolean,
  receiveLabels: (labels: RetainedSenderLabel[]) => void
): Promise<Message[]> {
  if (snapshot.length === 0) return [];
  const loadedIds = new Set(snapshot.map((message) => message.id));
  const { oldest, newest } = snapshot.reduce((range, message) => ({
    oldest: Math.min(range.oldest, message.conversation_sequence),
    newest: Math.max(range.newest, message.conversation_sequence)
  }), { oldest: Infinity, newest: 0 });
  const incoming: Message[] = [];
  await loadConversationCatchUp(
    api, conversationId, oldest - 1, newest + 1,
    current, receiveLabels,
    (page) => incoming.push(...page.filter((message) => loadedIds.has(message.id)))
  );
  return incoming;
}

export function mergeReconciledMessages(
  current: readonly Message[],
  snapshot: readonly Message[],
  incoming: readonly Message[]
): { messages: Message[]; changedDuringRead: boolean } {
  const before = new Map(snapshot.map((message) => [message.id, message]));
  const authoritative = new Map(incoming.map((message) => [message.id, message]));
  let changedDuringRead = false;
  const messages = current.flatMap((message) => {
    const previous = before.get(message.id);
    if (!previous) return [message]; // Preserve later sends and newly loaded pages.
    if (message !== previous) {
      changedDuringRead = true;
      return [message]; // A later event wins; reconcile it in the next pass.
    }
    const fresh = authoritative.get(message.id);
    return fresh ? [fresh] : []; // Rows outside the current authorized view disappear.
  });
  return { messages, changedDuringRead };
}
