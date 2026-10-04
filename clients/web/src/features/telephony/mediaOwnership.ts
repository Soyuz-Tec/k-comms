// Synchronous launch guard: a dial or answer reserves ownership before an API
// request can yield, so another surface cannot open a microphone concurrently.
let phoneMediaBusy = false;
const listeners = new Set<() => void>();

export function phoneMediaIsBusy(): boolean { return phoneMediaBusy; }

export function setPhoneMediaBusy(busy: boolean): void {
  if (phoneMediaBusy === busy) return;
  phoneMediaBusy = busy;
  // Local device tests release capture synchronously before Phone starts its
  // permission request; subscribers also update their visible controls.
  for (const listener of listeners) listener();
}

export function subscribePhoneMediaBusy(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
