import type { ApiClient } from "../../api";
import type { Message, RetainedSenderLabel } from "../../types";

export interface CatchUpRequest {
  afterSequence: number;
  beforeSequence?: number;
}

export function mergeCatchUpRequests(
  current: CatchUpRequest | null,
  incoming: CatchUpRequest
): CatchUpRequest {
  if (!current) return incoming;
  return {
    afterSequence: Math.min(
      current.afterSequence,
      incoming.afterSequence
    ),
    beforeSequence:
      current.beforeSequence === undefined ||
      incoming.beforeSequence === undefined
        ? undefined
        : Math.max(current.beforeSequence, incoming.beforeSequence)
  };
}

export async function loadConversationCatchUp(
  api: ApiClient,
  conversationId: string,
  afterSequence: number,
  beforeSequence: number | undefined,
  current: () => boolean,
  mergeRetainedSenderLabels: (labels: RetainedSenderLabel[]) => void,
  receiveMessages: (messages: Message[]) => void
): Promise<void> {
  let cursor = afterSequence;
  for (let pages = 0; current() && pages < 500; pages += 1) {
    const page =
      beforeSequence === undefined
        ? await api.messages(conversationId, cursor, 200)
        : await api.messages(
            conversationId,
            cursor,
            200,
            beforeSequence
          );
    if (!current()) return;
    mergeRetainedSenderLabels(page.included?.sender_labels || []);
    receiveMessages(page.data);
    if (!page.page.has_more) return;
    const next = page.page.next_after_sequence;
    if (next === null || next <= cursor) {
      throw new Error(
        "Realtime replay returned a non-advancing cursor."
      );
    }
    cursor = next;
  }
  if (current()) {
    throw new Error(
      "Realtime replay exceeded the safe catch-up limit."
    );
  }
}
