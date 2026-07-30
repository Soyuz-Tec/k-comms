import type { Message, RetainedSenderLabel } from "../../types";
import type { GuestRoomApi } from "./roomApi";

const guestMessagePageSize = 200;
const maxGuestCatchUpPages = 100;

export async function loadGuestMessageCatchUp(
  api: Pick<GuestRoomApi, "messages">,
  afterSequence: number,
  onSenderLabels?: (labels: RetainedSenderLabel[]) => void,
  throughSequence?: number
): Promise<Message[]> {
  const messages: Message[] = [];
  let cursor = afterSequence;

  for (let pageNumber = 0; pageNumber < maxGuestCatchUpPages; pageNumber += 1) {
    const page = await api.messages(cursor, guestMessagePageSize);
    const messagesInRange = page.data.filter(
      ({ conversation_sequence: sequence }) =>
        throughSequence === undefined || sequence <= throughSequence
    );
    const senderIdsInRange = new Set(
      messagesInRange.map(({ sender_user_id: senderUserId }) => senderUserId)
    );
    onSenderLabels?.(
      (page.included?.sender_labels || []).filter(
        ({ id }) => throughSequence === undefined || senderIdsInRange.has(id)
      )
    );
    messages.push(...messagesInRange);

    if (
      throughSequence !== undefined &&
      page.data.some(
        ({ conversation_sequence: sequence }) => sequence >= throughSequence
      )
    ) {
      return messages;
    }
    if (!page.page.has_more) return messages;

    const nextCursor = page.page.next_after_sequence;
    if (nextCursor === null || nextCursor <= cursor) {
      throw new Error(
        "K-Comms could not safely continue conversation catch-up. Refresh and try again."
      );
    }
    cursor = nextCursor;
  }

  throw new Error(
    "Conversation catch-up exceeded the safe page limit. Refresh to continue."
  );
}
