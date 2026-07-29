import { digestHex, hashBlobIncrementally } from "./sha256Core";

export interface Sha256WorkerRequest {
  blob: Blob;
}

export type Sha256WorkerResponse =
  | { hex: string; error?: undefined }
  | { hex?: undefined; error: string };

/**
 * The DOM lib types `self` as a Window, so the worker surface is declared
 * locally rather than pulling the WebWorker lib into the app project.
 */
interface WorkerScope {
  addEventListener(
    type: "message",
    listener: (event: { data: Sha256WorkerRequest }) => void
  ): void;
  postMessage(message: Sha256WorkerResponse): void;
}

const scope = self as unknown as WorkerScope;

scope.addEventListener("message", (event) => {
  void (async () => {
    try {
      const digest = await hashBlobIncrementally(event.data.blob);
      scope.postMessage({ hex: digestHex(digest) });
    } catch (reason: unknown) {
      scope.postMessage({
        error: reason instanceof Error ? reason.message : "Hashing failed"
      });
    }
  })();
});
