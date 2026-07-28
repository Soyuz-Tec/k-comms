const PWA_SCOPE = "/app/";
const PWA_WORKER_PATH = "/app/k-comms-sw.js";

let registrationPromise: Promise<ServiceWorkerRegistration | null> | null = null;

export function pwaWorkerUrl(): string {
  const revision =
    import.meta.env.VITE_K_COMMS_RELEASE_REVISION || "development";
  return `${PWA_WORKER_PATH}?revision=${encodeURIComponent(revision)}`;
}

export function supportsPwaRegistration(): boolean {
  return (
    typeof navigator !== "undefined" &&
    typeof navigator.serviceWorker?.register === "function"
  );
}

/**
 * Returns the single app-scoped service-worker registration used by both the
 * PWA lifecycle and browser push. Registration does not request notification
 * permission or create a push subscription.
 */
export function ensurePwaRegistration(): Promise<ServiceWorkerRegistration | null> {
  if (!supportsPwaRegistration()) return Promise.resolve(null);
  if (registrationPromise) return registrationPromise;

  registrationPromise = navigator.serviceWorker
    .register(pwaWorkerUrl(), {
      scope: PWA_SCOPE,
      type: "module",
      updateViaCache: "none"
    })
    .catch(() => {
      registrationPromise = null;
      return null;
    });

  return registrationPromise;
}

export function activateWaitingWorker(
  registration: ServiceWorkerRegistration,
  onActivated: () => void = () => window.location.reload()
): boolean {
  const waiting = registration.waiting;
  if (typeof navigator === "undefined") return false;

  if (!waiting) {
    // Another tab can activate the release after this tab showed its update
    // banner. Reloading is the only way for this stale client to load it.
    onActivated();
    return false;
  }

  let handled = false;
  const finish = () => {
    if (handled) return;
    handled = true;
    navigator.serviceWorker.removeEventListener("controllerchange", finish);
    waiting.removeEventListener("statechange", handleStateChange);
    onActivated();
  };
  const handleStateChange = () => {
    // Out-of-scope clients such as /admin do not receive controllerchange.
    // The waiting worker's activation state is the reliable fallback.
    if (waiting.state === "activated") finish();
  };

  navigator.serviceWorker.addEventListener("controllerchange", finish);
  waiting.addEventListener("statechange", handleStateChange);
  if (waiting.state === "activated") {
    finish();
    return false;
  }

  try {
    waiting.postMessage({ type: "SKIP_WAITING" });
  } catch {
    // The worker can disappear when another tab wins the activation race.
    finish();
    return false;
  }
  return true;
}

export function resetPwaRegistrationForTests(): void {
  registrationPromise = null;
}
