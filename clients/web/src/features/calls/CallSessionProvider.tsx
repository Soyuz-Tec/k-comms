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
  }, []);

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

  const audioEnabled =
    capabilities?.allow_audio_calls === true && audioCallsAvailable;
  const videoEnabled =
    capabilities?.allow_video_calls === true && videoCallsAvailable;

  return (
    <CallSessionContext.Provider value={value}>
      {children}
      {targetConversation && session && (
        <Suspense fallback={<span className="visually-hidden" role="status">Preparing call controls…</span>}>
          <PersistentCallPanel
            key={targetConversation.id}
            api={api}
            conversation={targetConversation}
            audioEnabled={audioEnabled}
            videoEnabled={videoEnabled}
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
          <button type="button" aria-label="Dismiss call notice" onClick={() => setNotice(null)}>×</button>
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

export function CallLaunchActions({
  conversation,
  audioEnabled,
  videoEnabled,
  showVideoAction = true
}: {
  conversation: Conversation;
  audioEnabled: boolean;
  videoEnabled: boolean;
  showVideoAction?: boolean;
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
        title={blockedTitle}
        aria-haspopup="dialog"
        aria-pressed={currentBusyKind === "audio"}
        onClick={() => launchCall(conversation, "audio")}
      >
        <span aria-hidden="true">◖</span>
        {!audioEnabled
          ? "Audio calls disabled"
          : currentBusyKind === "audio"
            ? sessionState?.joined ? "In audio call" : "Opening audio call…"
            : "Start audio call"}
      </button>
      {showVideoAction && (
        <button
          className={`button compact ${currentBusyKind === "video" ? "audio-call-active" : "ghost"}`}
          type="button"
          disabled={!videoEnabled || blockedByAnotherConversation}
          title={blockedTitle}
          aria-haspopup="dialog"
          aria-pressed={currentBusyKind === "video"}
          onClick={() => launchCall(conversation, "video")}
        >
          <span aria-hidden="true">▣</span>
          {!videoEnabled
            ? "Video calls disabled"
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
