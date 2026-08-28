import { useCallback, useSyncExternalStore } from "react";

/**
 * How the call control system should look and behave, per device.
 *
 * All three preferences the contract requires live here together, because
 * they answer one question -- "how should controls over video behave for me" --
 * and a person who needs one usually needs another. Splitting them across
 * modules would mean three storage conventions and three chances to disagree
 * about the fallback.
 *
 * Per device, not per account: the same person on a shared machine, a phone
 * and a desktop can reasonably want different answers, and none of this needs
 * the server to be involved.
 */
export interface CallControlPreferences {
  /** Keep routine controls on screen rather than letting them fade. */
  alwaysShow: boolean;
  /**
   * Replace the gradient scrims behind the controls with solid surfaces.
   *
   * A gradient keeps more of the picture visible, but it leaves the control
   * chrome sitting on whatever the video happens to be doing. Opaque trades
   * picture for a predictable background.
   */
  opaque: boolean;
  /** Raise the contrast of control edges and labels above the AA baseline. */
  highContrast: boolean;
}

export const CALL_CONTROL_PREFERENCE_KEYS = {
  alwaysShow: "k-comms.always-show-call-controls.v1",
  opaque: "k-comms.call-controls-opaque.v1",
  highContrast: "k-comms.call-controls-high-contrast.v1"
} as const satisfies Record<keyof CallControlPreferences, string>;

export type CallControlPreferenceName = keyof CallControlPreferences;

/**
 * Every preference defaults to off, but a storage failure defaults them on.
 *
 * The asymmetry is deliberate. Off is the designed experience; on is the
 * accessible one. If we cannot tell what someone chose, the safer guess is the
 * one that hides nothing and assumes nothing about their eyesight or their
 * display.
 */
const STORAGE_FAILURE_FALLBACK = true;

function readFlag(key: string): boolean {
  try {
    return window.localStorage.getItem(key) === "true";
  } catch {
    return STORAGE_FAILURE_FALLBACK;
  }
}

let snapshot: CallControlPreferences | null = null;
const listeners = new Set<() => void>();

function computeSnapshot(): CallControlPreferences {
  return {
    alwaysShow: readFlag(CALL_CONTROL_PREFERENCE_KEYS.alwaysShow),
    opaque: readFlag(CALL_CONTROL_PREFERENCE_KEYS.opaque),
    highContrast: readFlag(CALL_CONTROL_PREFERENCE_KEYS.highContrast)
  };
}

/**
 * useSyncExternalStore compares snapshots by identity, so this must return the
 * same object until something actually changes -- recomputing per call would
 * loop forever.
 */
export function getCallControlPreferences(): CallControlPreferences {
  snapshot ??= computeSnapshot();
  return snapshot;
}

function publish() {
  snapshot = computeSnapshot();
  for (const listener of listeners) listener();
}

export function setCallControlPreference(
  name: CallControlPreferenceName,
  value: boolean
): void {
  try {
    window.localStorage.setItem(CALL_CONTROL_PREFERENCE_KEYS[name], String(value));
  } catch {
    // The preference is lost for the next session, but the change still
    // applies to this one: publish regardless.
  }
  publish();
}

/**
 * Cross-tab sync.
 *
 * The snapshot is memoized for identity stability, which means a change made
 * in another tab would otherwise never be noticed -- someone turning on high
 * contrast in Settings while a call runs in a second tab would see nothing
 * happen in the call. The storage event is how that tab finds out.
 *
 * Attached only while something is subscribed, so nothing lingers when no
 * surface cares.
 */
function onStorage(event: StorageEvent) {
  const watched: string[] = Object.values(CALL_CONTROL_PREFERENCE_KEYS);
  // A null key means storage was cleared entirely, which affects all of them.
  if (event.key !== null && !watched.includes(event.key)) return;
  publish();
}

function subscribe(listener: () => void): () => void {
  if (listeners.size === 0) window.addEventListener("storage", onStorage);
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) window.removeEventListener("storage", onStorage);
  };
}

export function useCallControlPreferences(): CallControlPreferences {
  return useSyncExternalStore(subscribe, getCallControlPreferences, getCallControlPreferences);
}

export function useSetCallControlPreference(): (
  name: CallControlPreferenceName,
  value: boolean
) => void {
  return useCallback(setCallControlPreference, []);
}

/**
 * Publishes the appearance preferences to the document root for CSS.
 *
 * Only the two appearance preferences go to the DOM. `alwaysShow` changes
 * behaviour rather than appearance -- it is a keep-visible condition the
 * visibility hook reads directly, and nothing styles itself from it.
 *
 * Returns a cleanup that removes both, so a signed-out shell does not keep
 * styling itself as a call surface.
 */
export function applyCallControlPreferencesToDocument(
  preferences: CallControlPreferences
): () => void {
  const root = document.documentElement;
  if (preferences.opaque) root.dataset.callControls = "opaque";
  else delete root.dataset.callControls;
  if (preferences.highContrast) root.dataset.callContrast = "high";
  else delete root.dataset.callContrast;

  return () => {
    delete root.dataset.callControls;
    delete root.dataset.callContrast;
  };
}

/** Test seam: drops the memoized snapshot so storage is read afresh. */
export function resetCallControlPreferencesForTest(): void {
  snapshot = null;
  listeners.clear();
}
