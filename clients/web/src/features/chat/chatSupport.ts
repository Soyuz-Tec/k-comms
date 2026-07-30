import type {
  ConnectionStatus,
  RetainedSenderLabel
} from "../../types";

const senderLabelRefreshDelaysMs = [30_000, 60_000, 120_000, 300_000] as const;

export interface SenderLabelRefreshBackoff {
  conversationId: string | null;
  candidateSignature: string | null;
  resultSignature: string | null;
  delayIndex: number;
  nextAttemptAt: number;
}

export function conversationInitials(title: string): string {
  return title
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0]?.toLocaleUpperCase() || "")
    .join("") || "@";
}

export function newSenderLabelRefreshBackoff(
  conversationId: string | null
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

export function connectionLabel(status: ConnectionStatus): string {
  if (status === "live") return "Live";
  if (status === "connecting") return "Connecting";
  if (status === "reconnecting") return "Reconnecting";
  return "Offline";
}

export function formatAttachmentLimit(value: number): string {
  return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(value % 1_000_000 === 0 ? 0 : 1)} MB` : `${Math.ceil(value / 1_000)} KB`;
}

export function abortableDelay(milliseconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new DOMException("The upload was cancelled", "AbortError"));
      return;
    }
    const timer = window.setTimeout(resolve, milliseconds);
    signal.addEventListener("abort", () => {
      window.clearTimeout(timer);
      reject(new DOMException("The upload was cancelled", "AbortError"));
    }, { once: true });
  });
}

export function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

export function attachmentCancelled(
  clientId: string,
  controller: AbortController,
  cancelled: { current: Set<string> }
): boolean {
  return controller.signal.aborted || cancelled.current.has(clientId);
}

export function safeUuid(value: string | null): string | null {
  return value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

export function safePositiveInteger(value: string | null): number | null {
  if (!value || !/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

export function safeCallKind(value: string | null): "audio" | "video" | null {
  return value === "audio" || value === "video" ? value : null;
}

export function readOnboardingPreference(storageKey: string): boolean {
  try { return window.localStorage.getItem(storageKey) !== "dismissed"; } catch { return true; }
}
