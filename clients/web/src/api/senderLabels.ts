import type { RetainedSenderLabel } from "../types";

const senderLabelBatchSize = 200;

export async function resolveSenderLabelBatches(
  messageIds: string[],
  resolveBatch: (messageIds: string[]) => Promise<RetainedSenderLabel[]>
): Promise<RetainedSenderLabel[]> {
  const normalizedIds = [...new Set(messageIds)].sort();
  const labels: RetainedSenderLabel[] = [];

  for (let offset = 0; offset < normalizedIds.length; offset += senderLabelBatchSize) {
    labels.push(
      ...await resolveBatch(
        normalizedIds.slice(offset, offset + senderLabelBatchSize)
      )
    );
  }

  return labels;
}
