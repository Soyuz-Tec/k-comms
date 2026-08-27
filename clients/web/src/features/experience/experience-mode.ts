/**
 * The experience-mode state machine.
 *
 * Presentation is explicit state, not a CSS selector. The previous call
 * surface decided how much of the shell to show by matching class names in
 * five separate stylesheets, which is why `.audio-call-dock.minimized` could
 * silently hide the whole control set: no single place knew what "minimized"
 * was supposed to mean.
 *
 * The type is three-valued so a later Focus experiment does not have to
 * introduce an incompatible state model. Focus is not first-increment
 * functionality: ENTER_FOCUS returns the current state unless an authorizing
 * flag is passed, so production exposes only `workspace | immersive`.
 */
export type ExperienceMode = "workspace" | "focus" | "immersive";

export interface ExperienceState {
  mode: ExperienceMode;
  /**
   * The call the current presentation decision is bound to.
   *
   * This is what makes the decision sticky. Once media connection has begun
   * for a call, a later capability result must not re-decide its presentation
   * -- upgrading mid-call would remount the media tree and drop the call.
   */
  decidedForCallId: string | null;
  /**
   * Set when the server withdraws the capability while a call is running. It
   * blocks the *next* Immersive entry without touching the current one.
   */
  entryWithdrawn: boolean;
}

export const initialExperienceState: ExperienceState = {
  mode: "workspace",
  decidedForCallId: null,
  entryWithdrawn: false
};

export type ExperienceAction =
  /**
   * The decision taken at the join deadline, dispatched exactly once per call
   * immediately before media connection begins.
   */
  | { type: "CALL_JOINED"; callId: string; immersive: boolean }
  | { type: "CALL_LEFT" }
  /**
   * Focus is design-only in this increment. `authorized` is supplied by the
   * approved experiment flag for the current route and user; without it this
   * action is a no-op by contract, not by omission.
   */
  | { type: "ENTER_FOCUS"; authorized?: boolean }
  | { type: "EXIT_TO_WORKSPACE" }
  /** Server emergency disable: no new Immersive entries, current call unchanged. */
  | { type: "WITHDRAW_ENTRY" }
  | { type: "RESTORE_ENTRY" };

export function experienceReducer(
  state: ExperienceState,
  action: ExperienceAction
): ExperienceState {
  switch (action.type) {
    case "CALL_JOINED": {
      // Sticky: the presentation for a joined call is decided once. A repeat
      // decision for the same call -- a late capability result, a re-render,
      // a reconnect -- is discarded rather than applied.
      if (state.decidedForCallId === action.callId) return state;
      const immersive = action.immersive && !state.entryWithdrawn;
      return {
        ...state,
        mode: immersive ? "immersive" : "workspace",
        decidedForCallId: action.callId
      };
    }
    case "CALL_LEFT":
      if (state.decidedForCallId === null && state.mode === "workspace") return state;
      return { ...state, mode: "workspace", decidedForCallId: null };
    case "ENTER_FOCUS":
      if (!action.authorized) return state;
      if (state.mode === "focus") return state;
      return { ...state, mode: "focus" };
    case "EXIT_TO_WORKSPACE":
      if (state.mode === "workspace") return state;
      return { ...state, mode: "workspace" };
    case "WITHDRAW_ENTRY":
      if (state.entryWithdrawn) return state;
      return { ...state, entryWithdrawn: true };
    case "RESTORE_ENTRY":
      if (!state.entryWithdrawn) return state;
      return { ...state, entryWithdrawn: false };
    default:
      return state;
  }
}
