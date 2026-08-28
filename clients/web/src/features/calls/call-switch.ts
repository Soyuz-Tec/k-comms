import type { CallMediaKind } from "../../types";
import type { CallReadinessMode } from "./callReadinessNavigation";
import type { CallPanelSessionState } from "./callContracts";

/**
 * Switching from one call to another.
 *
 * The contract allows exactly one locally joined room, so a second call is
 * never connected alongside the first. Accepting one is therefore not "join
 * the new call" but a sequence: confirm, leave the current call, *observe*
 * that it actually released, and only then join.
 *
 * The order is the whole point, and so is the observation. "Complete and
 * reconcile the current leave before joining the next call; never claim
 * success while leave is pending or failed" rules out the obvious
 * implementation -- fire a leave, optimistically join -- because a leave that
 * stalls or fails would leave two rooms connected, or one room gone and
 * nothing to show for it.
 */
export type CallSwitchPhase = "idle" | "confirming" | "leaving" | "failed";

export interface PendingCallSwitch {
  conversationId: string;
  conversationTitle: string;
  kind: CallMediaKind;
  readinessMode: CallReadinessMode | null;
  /** What the user is being asked to leave, for an honest prompt. */
  leavingTitle: string;
}

export interface CallSwitchState {
  phase: CallSwitchPhase;
  pending: PendingCallSwitch | null;
  /** Set only in the failed phase; always describes what actually happened. */
  failure: string | null;
}

export const initialCallSwitchState: CallSwitchState = {
  phase: "idle",
  pending: null,
  failure: null
};

/**
 * How long the previous call has to release before the switch is reported as
 * failed.
 *
 * Generous, because a leave crosses the network and a slow one is not a
 * broken one. What it must never do is wait forever: an unbounded wait is
 * indistinguishable to the user from a switch that silently did nothing.
 */
export const CALL_SWITCH_LEAVE_TIMEOUT_MS = 15_000;

export type CallSwitchAction =
  | { type: "REQUEST"; pending: PendingCallSwitch }
  | { type: "CANCEL" }
  | { type: "CONFIRM" }
  | { type: "RELEASED" }
  | { type: "FAILED"; reason: string }
  | { type: "DISMISS" };

export function callSwitchReducer(
  state: CallSwitchState,
  action: CallSwitchAction
): CallSwitchState {
  switch (action.type) {
    case "REQUEST":
      // A request that arrives mid-switch is dropped rather than queued: the
      // user is already answering a question about which call they want.
      if (state.phase === "leaving") return state;
      return { phase: "confirming", pending: action.pending, failure: null };
    case "CONFIRM":
      if (state.phase !== "confirming" || !state.pending) return state;
      return { ...state, phase: "leaving", failure: null };
    case "RELEASED":
      if (state.phase !== "leaving") return state;
      return { ...initialCallSwitchState };
    case "FAILED":
      if (state.phase !== "leaving") return state;
      // The pending target is kept so the message can name the call that was
      // not joined, rather than saying something vague went wrong.
      return { ...state, phase: "failed", failure: action.reason };
    case "CANCEL":
    case "DISMISS":
      if (state.phase === "idle") return state;
      return { ...initialCallSwitchState };
    default:
      return state;
  }
}

/**
 * Whether the previous call has released its local connection.
 *
 * Deliberately not called "leaveSucceeded". `error` counts here because an
 * errored call is not holding a room -- but nothing about that is a
 * successful leave, and the distinction matters for what the user is told.
 * A call still in `leaving` has *not* released: that is the pending state the
 * contract forbids treating as done.
 */
export function previousCallReleased(state: CallPanelSessionState | null): boolean {
  if (!state) return true;
  return state.phase === "ended" || state.phase === "idle" || state.phase === "error";
}

/**
 * The message shown when a switch could not complete.
 *
 * It says the original call is still there, because that is the fact the user
 * most needs and the one a vague failure would leave them guessing about.
 */
export function switchFailureMessage(pending: PendingCallSwitch | null): string {
  const target = pending?.conversationTitle ?? "the other conversation";
  const origin = pending?.leavingTitle ?? "your current call";
  return `Could not leave ${origin}, so the call in ${target} was not joined. You are still in ${origin}.`;
}
