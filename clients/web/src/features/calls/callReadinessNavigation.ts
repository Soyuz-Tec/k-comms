export const OFFICE_CALL_READINESS_MODE = "office" as const;

export type CallReadinessMode = typeof OFFICE_CALL_READINESS_MODE;

export function safeCallReadinessMode(value: string | null): CallReadinessMode | null {
  return value === OFFICE_CALL_READINESS_MODE ? value : null;
}

export function callReadinessGuestUrl(value: string): string {
  const url = new URL(value);
  url.searchParams.set("call", "audio");
  url.searchParams.set("call_readiness", OFFICE_CALL_READINESS_MODE);
  return url.toString();
}

export function callReadinessHostPath(conversationId: string): string {
  const query = new URLSearchParams({
    conversation: conversationId,
    call: "audio",
    call_readiness: OFFICE_CALL_READINESS_MODE
  });
  return `/app/?${query.toString()}`;
}

export function clearCallReadinessSearch(value: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(value);
  next.delete("call");
  next.delete("call_readiness");
  return next;
}
