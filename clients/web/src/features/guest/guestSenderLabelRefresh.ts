import type { RetainedSenderLabel } from "../../types";

const senderLabelRefreshDelaysMs = [30_000, 60_000, 120_000, 300_000] as const;

export interface SenderLabelRefreshBackoff {
  conversationId: string;
  candidateSignature: string | null;
  resultSignature: string | null;
  delayIndex: number;
  nextAttemptAt: number;
}

export function newSenderLabelRefreshBackoff(
  conversationId: string
): SenderLabelRefreshBackoff {
  return {
    conversationId,
    candidateSignature: null,
    resultSignature: null,
    delayIndex: 0,
    nextAttemptAt: 0
  };
}

export function senderLabelRefreshAllowed(
  backoffRef: { current: SenderLabelRefreshBackoff },
  conversationId: string,
  messageIds: string[]
): boolean {
  const candidateSignature = JSON.stringify([...messageIds].sort());
  let current = backoffRef.current;
  if (
    current.conversationId !== conversationId ||
    current.candidateSignature !== candidateSignature
  ) {
    current = {
      ...newSenderLabelRefreshBackoff(conversationId),
      candidateSignature
    };
    backoffRef.current = current;
  }
  return (
    document.visibilityState === "visible" &&
    Date.now() >= current.nextAttemptAt
  );
}

export function recordSenderLabelRefresh(
  backoffRef: { current: SenderLabelRefreshBackoff },
  conversationId: string,
  messageIds: string[],
  labels: RetainedSenderLabel[]
): void {
  const candidateSignature = JSON.stringify([...messageIds].sort());
  const resultSignature = JSON.stringify(
    [...labels]
      .sort((left, right) => left.id.localeCompare(right.id))
      .map(({ id, display_name, redacted }) => [id, display_name, redacted])
  );
  const current = backoffRef.current;
  if (
    current.conversationId !== conversationId ||
    current.candidateSignature !== candidateSignature
  ) {
    return;
  }
  const changed =
    current.resultSignature !== null &&
    current.resultSignature !== resultSignature;
  const delayIndex =
    current.resultSignature === null || changed
      ? 0
      : Math.min(
          current.delayIndex + 1,
          senderLabelRefreshDelaysMs.length - 1
        );
  const delayMs =
    senderLabelRefreshDelaysMs[delayIndex] ??
    300_000;
  backoffRef.current = {
    ...current,
    resultSignature,
    delayIndex,
    nextAttemptAt: Date.now() + delayMs
  };
}
