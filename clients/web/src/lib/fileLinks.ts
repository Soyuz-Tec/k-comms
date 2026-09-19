import type { FileSummary } from "../types";

export function fileSourceMessagePath(file: Pick<FileSummary, "conversation_id" | "message_id" | "conversation_sequence">): string {
  const query = new URLSearchParams({
    conversation: file.conversation_id,
    search_message: file.message_id,
    search_sequence: String(file.conversation_sequence)
  });
  return `/app/?${query.toString()}`;
}
