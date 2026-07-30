export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly meta?: unknown;
  readonly retryAfterSeconds?: number;

  constructor(
    status: number,
    code: string,
    message: string,
    meta?: unknown,
    retryAfterSeconds?: number
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.meta = meta;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export function retryAfterSeconds(value: string | null): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.ceil(seconds);

  const deadline = Date.parse(value);
  if (!Number.isFinite(deadline)) return undefined;
  return Math.max(0, Math.ceil((deadline - Date.now()) / 1_000));
}
