import {
  createContext,
  lazy,
  Suspense,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState
} from "react";
import type { ReactNode } from "react";
import { useNavigate } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import type {
  CallMediaKind,
  CallRealtimeEvent,
  Conversation
} from "../../types";
import type { CallPanelSessionState } from "./CallPanel";
import { requestCallSessionTeardown } from "./callSessionEvents";

const PersistentCallPanel = lazy(() =>
  import("./CallPanel").then(({ CallPanel }) => ({ default: CallPanel }))
);

interface LaunchRequest {
  id: number;
  kind: CallMediaKind;
}

interface CallSessionContextValue {
  targetConversation: Conversation | null;
  sessionState: CallPanelSessionState | null;
  launchRequest: LaunchRequest | null;
  launchCall: (conversation: Conversation, kind: CallMediaKind) => boolean;
  publishRealtimeEvent: (event: CallRealtimeEvent) => void;
  teardownCall: () => void;
}

const CallSessionContext = createContext<CallSessionContextValue | null>(null);

export function CallSessionProvider({ children }: { children: ReactNode }) {
  const navigate = useNavigate();
  const { api, session } = useSession();
  const {
    audioCallsAvailable,
    capabilities,
    loading: workspaceLoading,
    videoCallsAvailable
  } = useWorkspaceData();
  const [targetConversation, setTargetConversation] = useState<Conversation | null>(null);
  const [sessionState, setSessionState] = useState<CallPanelSessionState | null>(null);
  const [launchRequest, setLaunchRequest] = useState<LaunchRequest | null>(null);
  const [realtimeEvent, setRealtimeEvent] = useState<CallRealtimeEvent | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const requestSequenceRef = useRef(0);
  const targetConversationRef = useRef<Conversation | null>(null);
  const sessionStateRef = useRef<CallPanelSessionState | null>(null);
  const launchRequestRef = useRef<LaunchRequest | null>(null);

  const launchCall = useCallback((conversation: Conversation, kind: CallMediaKind) => {
    if (workspaceLoading || !capabilities) {
      setNotice("Call availability is still being checked. Try again shortly.");
      return false;
    }
    const allowed = kind === "audio"
      ? capabilities.allow_audio_calls === true
      : capabilities.allow_video_calls === true;
    if (!allowed) {
      setNotice(
        `${kind === "audio" ? "Audio" : "Video"} calling is disabled by workspace policy. Keep messaging or ask a workspace administrator.`
      );
      return false;
    }
    const available = kind === "audio"
      ? audioCallsAvailable
      : videoCallsAvailable;
    if (!available) {
      setNotice(
        `${kind === "audio" ? "Audio" : "Video"} calling is temporarily unavailable. Open Calls and refresh call availability.`
      );
      return false;
    }

    const currentTarget = targetConversationRef.current;
    const currentState = sessionStateRef.current;
    const pendingRequest = launchRequestRef.current;
    const busy = Boolean(pendingRequest) || callSessionIsBusy(currentState);
    if (busy && currentTarget?.id !== conversation.id) {
      setNotice(
        `Leave or cancel the current ${currentState?.mediaKind || pendingRequest?.kind || "active"} call before opening another conversation.`
      );
      return false;
    }
    if (busy) {
      setNotice(
        currentState?.joined
          ? `You are already in the ${currentState.mediaKind} call for ${currentTarget?.title || "this conversation"}.`
          : `Finish or cancel the current ${currentState?.mediaKind || pendingRequest?.kind || kind} call lobby first.`
      );
      return false;
    }

    const request = { id: ++requestSequenceRef.current, kind };
    targetConversationRef.current = conversation;
    launchRequestRef.current = request;
    sessionStateRef.current = null;
    setTargetConversation(conversation);
    setSessionState(null);
    setRealtimeEvent(null);
    setNotice(null);
    setLaunchRequest(request);
    return true;
  }, [
    audioCallsAvailable,
    capabilities,
    videoCallsAvailable,
    workspaceLoading
  ]);

  const publishRealtimeEvent = useCallback((event: CallRealtimeEvent) => {
    if (targetConversationRef.current?.id === event.conversation_id) {
      setRealtimeEvent(event);
    }
  }, []);

  const sessionChanged = useCallback((next: CallPanelSessionState) => {
    if (targetConversationRef.current?.id !== next.conversationId) return;
    sessionStateRef.current = next;
    setSessionState(next);
  }, []);

  const launchConsumed = useCallback(() => {
    launchRequestRef.current = null;
    setLaunchRequest(null);
  }, []);

  const value = useMemo(
    () => ({
      targetConversation,
      sessionState,
      launchRequest,
      launchCall,
      publishRealtimeEvent,
      teardownCall: requestCallSessionTeardown
    }),
    [
      launchCall,
      launchRequest,
      publishRealtimeEvent,
      sessionState,
      targetConversation
    ]
  );

  // Provider readiness is a new-launch guard. Once a room is open, only an
  // explicit workspace-policy revocation should tear it down; a transient
  // readiness probe must not eject an otherwise connected participant.
  const audioPolicyEnabled = capabilities?.allow_audio_calls === true;
  const videoPolicyEnabled = capabilities?.allow_video_calls === true;

  return (
    <CallSessionContext.Provider value={value}>
      {children}
      {targetConversation && session && (
        <Suspense fallback={<span className="visually-hidden" role="status">Preparing call controls…</span>}>
          <PersistentCallPanel
            key={targetConversation.id}
            api={api}
            conversation={targetConversation}
            audioEnabled={audioPolicyEnabled}
            videoEnabled={videoPolicyEnabled}
            currentUserDisplayName={session.user.display_name}
            realtimeEvent={realtimeEvent}
            launchRequest={launchRequest?.kind}
            launchRequestId={launchRequest?.id}
            onLaunchRequestConsumed={launchConsumed}
            onNavigate={navigate}
            onSessionStateChange={sessionChanged}
            renderActions={false}
          />
        </Suspense>
      )}
      {notice && (
        <div className="call-session-launch-notice" role="status">
          <span>{notice}</span>
          <button type="button" aria-label="Dismiss call notice" onClick={() => setNotice(null)}><AppIcon name="x" /></button>
        </div>
      )}
    </CallSessionContext.Provider>
  );
}

export function useCallSession(): CallSessionContextValue {
  const value = useContext(CallSessionContext);
  if (!value) throw new Error("useCallSession must be used within CallSessionProvider");
  return value;
}

function CallKindIcon({ kind }: { kind: "audio" | "video" }) {
  return <AppIcon name={kind === "audio" ? "phone" : "video"} />;
}

export function CallLaunchActions({
  conversation,
  audioEnabled,
  videoEnabled,
  showVideoAction = true,
  availabilityDescriptionId
}: {
  conversation: Conversation;
  audioEnabled: boolean;
  videoEnabled: boolean;
  showVideoAction?: boolean;
  availabilityDescriptionId?: string;
}) {
  const { launchCall, launchRequest, sessionState, targetConversation } = useCallSession();
  const current = targetConversation?.id === conversation.id;
  const busy = callSessionIsBusy(sessionState) || Boolean(launchRequest);
  const blockedByAnotherConversation = busy && !current;
  const currentKind = sessionState?.mediaKind || launchRequest?.kind;
  const currentBusyKind = current && busy ? currentKind : null;

  const blockedTitle = blockedByAnotherConversation
    ? "Leave or cancel the current call before starting another."
    : undefined;

  return (
    <div className="call-control audio-call-control">
      <button
        className={`button compact ${currentBusyKind === "audio" ? "audio-call-active" : "ghost"}`}
        type="button"
        disabled={!audioEnabled || blockedByAnotherConversation}
        title={!audioEnabled ? "Audio calling is unavailable. See the adjacent guidance." : blockedTitle}
        aria-describedby={!audioEnabled ? availabilityDescriptionId : undefined}
        aria-haspopup="dialog"
        aria-pressed={currentBusyKind === "audio"}
        onClick={() => launchCall(conversation, "audio")}
      >
        <span aria-hidden="true"><CallKindIcon kind="audio" /></span>
        {!audioEnabled
          ? "Audio calling unavailable"
          : currentBusyKind === "audio"
            ? sessionState?.joined ? "In audio call" : "Opening audio call…"
            : "Start audio call"}
      </button>
      {showVideoAction && (
        <button
          className={`button compact ${currentBusyKind === "video" ? "audio-call-active" : "ghost"}`}
          type="button"
          disabled={!videoEnabled || blockedByAnotherConversation}
          title={!videoEnabled ? "Video calling is unavailable. See the adjacent guidance." : blockedTitle}
          aria-describedby={!videoEnabled ? availabilityDescriptionId : undefined}
          aria-haspopup="dialog"
          aria-pressed={currentBusyKind === "video"}
          onClick={() => launchCall(conversation, "video")}
        >
          <span aria-hidden="true"><CallKindIcon kind="video" /></span>
          {!videoEnabled
            ? "Video calling unavailable"
            : currentBusyKind === "video"
              ? sessionState?.joined ? "In video call" : "Opening video call…"
              : "Start video call"}
        </button>
      )}
    </div>
  );
}

export function CallLaunchButton({
  conversation,
  kind,
  children,
  className,
  ariaLabel,
  disabled = false
}: {
  conversation: Conversation;
  kind: CallMediaKind;
  children: ReactNode;
  className?: string;
  ariaLabel?: string;
  disabled?: boolean;
}) {
  const { launchCall, launchRequest, sessionState, targetConversation } = useCallSession();
  const busy = callSessionIsBusy(sessionState) || Boolean(launchRequest);
  const blocked = busy && targetConversation?.id !== conversation.id;
  const currentBusy = busy && targetConversation?.id === conversation.id;
  return (
    <button
      className={className}
      type="button"
      disabled={disabled || blocked || currentBusy}
      title={blocked ? "Leave or cancel the current call before starting another." : undefined}
      aria-label={ariaLabel}
      aria-haspopup="dialog"
      onClick={() => launchCall(conversation, kind)}
    >
      {children}
    </button>
  );
}

export function callSessionIsBusy(state: CallPanelSessionState | null): boolean {
  return Boolean(
    state &&
    ["prejoin", "joining", "connected", "reconnecting", "leaving"].includes(state.phase)
  );
}
