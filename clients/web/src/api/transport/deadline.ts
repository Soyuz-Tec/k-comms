import { ApiError } from "../errors";

const apiRequestDeadlineMs = 30_000;

interface DeadlineResponse<T> {
  response: Response;
  body: T;
}

export async function fetchWithApiDeadline<T>(
  input: RequestInfo | URL,
  init: RequestInit,
  readBody: (response: Response) => Promise<T>
): Promise<DeadlineResponse<T>> {
  const callerSignal = init.signal;
  const controller = new AbortController();
  let abortSource: "caller" | "deadline" | null = null;
  const timeoutError = new ApiError(
    408,
    "request_timeout",
    "K-Comms did not respond in time. Try again."
  );

  const abortFromCaller = () => {
    if (abortSource) return;
    abortSource = "caller";
    controller.abort(callerSignal?.reason);
  };

  if (callerSignal?.aborted) {
    abortFromCaller();
  } else {
    callerSignal?.addEventListener("abort", abortFromCaller, { once: true });
  }

  const timeout = globalThis.setTimeout(() => {
    if (abortSource) return;
    abortSource = "deadline";
    controller.abort(timeoutError);
  }, apiRequestDeadlineMs);

  try {
    const response = await fetch(input, { ...init, signal: controller.signal });
    return { response, body: await readBody(response) };
  } catch (error) {
    if (abortSource === "deadline") throw timeoutError;
    throw error;
  } finally {
    globalThis.clearTimeout(timeout);
    callerSignal?.removeEventListener("abort", abortFromCaller);
  }
}
