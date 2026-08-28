import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef
} from "react";
import type { ReactNode } from "react";
import { useWorkspaceData } from "../../app/workspace-data";
import { useCallSession } from "../calls/CallSessionProvider";
import {
  experienceReducer,
  initialExperienceState,
  type ExperienceMode
} from "./experience-mode";
import {
  applyCallControlPreferencesToDocument,
  useCallControlPreferences
} from "./call-control-preferences";
import { setExperienceModeSnapshot } from "./experience-mode-store";
import {
  resolveImmersiveWithinDeadline,
  selectImmersiveEligibility,
  type ImmersiveSubjectCapabilities
} from "./immersive-eligibility";
import type { ServiceStatus } from "../../types";

interface ExperienceModeValue {
  mode: ExperienceMode;
  /** True while the deployment and the tenant both permit Immersive Mode. */
  immersiveEligible: boolean;
  exitToWorkspace: () => void;
}

const ExperienceModeContext = createContext<ExperienceModeValue | null>(null);

/**
 * Binds the experience mode to the live call.
 *
 * The decision is taken once per call, at the moment media connection begins
 * -- the `joining` phase -- rather than when the call reports itself
 * connected. Deciding on `connected` would let a capability result that
 * arrived during connection flip the presentation of a call already on
 * screen, which is exactly the mid-call remount §7.3 forbids.
 *
 * The binding key is the conversation rather than the call id: a call id is
 * still null while joining, so keying on it would decide twice for one call
 * and defeat the stickiness guard.
 */
export interface ExperienceModeInputs {
  /** The live call, or null. Only `conversationId` and `phase` are read. */
  sessionState: { conversationId: string; phase: string } | null;
  status: ServiceStatus | null | undefined;
  capabilities: ImmersiveSubjectCapabilities | null | undefined;
  /** True while capability retrieval is still in flight. */
  loading: boolean;
}

/**
 * The decision engine, with its inputs handed to it.
 *
 * Members read them from the workspace, guests from their session, and
 * instant-room participants from the room -- three different responses
 * answering the same question. Passing them in is what lets all three share
 * one reducer, one deadline and one stickiness guard, rather than the public
 * routes growing a parallel copy that drifts.
 */
export function useExperienceModeController({
  sessionState,
  status,
  capabilities,
  loading
}: ExperienceModeInputs) {
  const [state, dispatch] = useReducer(experienceReducer, initialExperienceState);

  const immersiveEligible = useMemo(
    () => selectImmersiveEligibility(status, capabilities),
    [status, capabilities]
  );

  /*
   * Capability retrieval starts when the workspace loads, long before any
   * prejoin surface, so by the time Join is pressed the answer is normally
   * already known. This resolver covers the case where it is not: rather than
   * dropping an eligible user to the legacy UI because their capability
   * request is a few milliseconds behind, the join waits out the deadline.
   */
  const pendingDecision = useRef<{
    promise: Promise<boolean>;
    settle: (eligible: boolean) => void;
  } | null>(null);

  if (pendingDecision.current === null) {
    let settle: (eligible: boolean) => void = () => {};
    const promise = new Promise<boolean>((resolve) => {
      settle = resolve;
    });
    pendingDecision.current = { promise, settle };
  }

  useEffect(() => {
    if (loading) return;
    pendingDecision.current?.settle(immersiveEligible);
  }, [loading, immersiveEligible]);

  const joiningConversationId =
    sessionState && sessionState.phase === "joining" ? sessionState.conversationId : null;
  const activeConversationId = sessionState?.conversationId ?? null;
  const decidedForCallId = state.decidedForCallId;

  useEffect(() => {
    if (!joiningConversationId) return;
    if (decidedForCallId === joiningConversationId) return;

    let live = true;
    const decision = loading
      ? resolveImmersiveWithinDeadline(pendingDecision.current!.promise)
      : Promise.resolve(immersiveEligible);

    void decision.then((immersive) => {
      if (!live) return;
      dispatch({ type: "CALL_JOINED", callId: joiningConversationId, immersive });
    });

    return () => {
      live = false;
    };
  }, [joiningConversationId, decidedForCallId, loading, immersiveEligible]);

  // The call is gone, or moved to a different conversation entirely.
  useEffect(() => {
    if (decidedForCallId === null) return;
    if (activeConversationId === decidedForCallId) return;
    dispatch({ type: "CALL_LEFT" });
  }, [activeConversationId, decidedForCallId]);

  /*
   * A server that withdraws the capability mid-call blocks the next Immersive
   * entry and leaves the current call alone. There is no tested same-session
   * visual downgrade, so tearing the running call's presentation down here
   * would be an untested path taken during an incident.
   */
  useEffect(() => {
    dispatch({ type: immersiveEligible ? "RESTORE_ENTRY" : "WITHDRAW_ENTRY" });
  }, [immersiveEligible]);

  /*
   * The mode is published on the document root, not on .app-shell.
   *
   * CallSessionProvider renders the persistent call panel as a *sibling* of
   * its children, so the call dock is not a descendant of the shell -- a
   * selector rooted at .app-shell cannot reach it, and the panel sits outside
   * this provider so it cannot read the context either. The document root is
   * the one ancestor both share.
   *
   * This also replaces what `body:has(.video-call-dock:not(.minimized))` was
   * doing: asking what the call surface currently looks like, rather than
   * being told what mode we are in.
   */
  useEffect(() => {
    const root = document.documentElement;
    root.dataset.experienceMode = state.mode;
    // The same value, published twice from one place: the attribute for CSS,
    // the store for the call panel, which renders outside this provider.
    setExperienceModeSnapshot(state.mode);
    return () => {
      delete root.dataset.experienceMode;
      setExperienceModeSnapshot("workspace");
    };
  }, [state.mode]);

  /*
   * The appearance preferences are published here because this provider is
   * mounted for the whole authenticated shell, while the control that changes
   * them lives in Settings and the surface that obeys them is the call panel.
   * Neither of those is an ancestor of the other, so the document root is
   * again the shared ground -- the same arrangement the experience mode uses.
   */
  const callControlPreferences = useCallControlPreferences();
  useEffect(
    () => applyCallControlPreferencesToDocument(callControlPreferences),
    [callControlPreferences]
  );

  const exitToWorkspace = useCallback(() => {
    dispatch({ type: "EXIT_TO_WORKSPACE" });
  }, []);

  return useMemo(
    () => ({ mode: state.mode, immersiveEligible, exitToWorkspace }),
    [state.mode, immersiveEligible, exitToWorkspace]
  );
}

/**
 * The authenticated shell's provider.
 *
 * It exists on top of the controller only to publish the mode as context,
 * which ProductShellContent uses to unmount the sidebar and bottom navigation.
 * Guest and instant-room routes have no authenticated chrome to unmount, so
 * they call the controller directly and never mount this.
 */
export function ExperienceModeProvider({ children }: { children: ReactNode }) {
  const { sessionState } = useCallSession();
  const { capabilities, serviceStatus, loading } = useWorkspaceData();
  const value = useExperienceModeController({
    sessionState,
    status: serviceStatus,
    capabilities,
    loading
  });

  return (
    <ExperienceModeContext.Provider value={value}>{children}</ExperienceModeContext.Provider>
  );
}

export function useExperienceMode(): ExperienceModeValue {
  const value = useContext(ExperienceModeContext);
  if (!value) throw new Error("useExperienceMode must be used within ExperienceModeProvider");
  return value;
}
