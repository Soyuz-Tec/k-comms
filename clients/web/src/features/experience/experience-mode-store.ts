import { useSyncExternalStore } from "react";
import type { ExperienceMode } from "./experience-mode";

/**
 * The current experience mode, readable from outside the provider's tree.
 *
 * CallSessionProvider renders the persistent call panel as a *sibling* of its
 * children, so the panel is not inside ExperienceModeProvider and cannot use
 * the context. It still has to know the mode: on the Immersive stage its
 * routine controls auto-hide and its critical status takes over, and in
 * Workspace they do not.
 *
 * The alternative was reading `data-experience-mode` off the document root
 * with a MutationObserver. That works, but it makes the DOM the source of
 * truth for a decision the reducer already owns -- the exact arrangement the
 * mode was introduced to replace. This keeps one owner and gives the DOM
 * attribute and this store the same origin.
 */
let currentMode: ExperienceMode = "workspace";
const listeners = new Set<() => void>();

export function setExperienceModeSnapshot(next: ExperienceMode): void {
  if (next === currentMode) return;
  currentMode = next;
  for (const listener of listeners) listener();
}

export function getExperienceModeSnapshot(): ExperienceMode {
  return currentMode;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/**
 * Reads the mode without needing to sit under the provider.
 *
 * The server snapshot is the same value: the store starts in "workspace" and
 * only a mounted provider moves it, so there is nothing for a hydration pass
 * to disagree about.
 */
export function useExperienceModeSnapshot(): ExperienceMode {
  return useSyncExternalStore(subscribe, getExperienceModeSnapshot, getExperienceModeSnapshot);
}
