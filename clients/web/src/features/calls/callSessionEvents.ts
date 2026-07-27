export const CALL_SESSION_TEARDOWN_EVENT = "k-comms:call-session-teardown";

export function requestCallSessionTeardown() {
  window.dispatchEvent(new Event(CALL_SESSION_TEARDOWN_EVENT));
}
