import { useCallback, useEffect } from "react";
import type { MutableRefObject } from "react";
import type { Room } from "livekit-client";
import { errorText } from "../../lib/format";
import type {
  Call,
  CallMediaKind,
  CallRealtimeEvent
} from "../../types";
import type { CallApi, CallPhase } from "./callContracts";
import { callMediaKind, getCall } from "./callMedia";

export function useCallControlPlane({
  api,
  available,
  conversationId,
  currentCallId,
  currentMediaKind,
  disconnectEndedCall,
  latestRealtimeEventRef,
  accessRevokedRef,
  operationIsCurrent,
  operationGenerationRef,
  phase,
  roomRef,
  refreshSequenceRef,
  setCall,
  setError,
  setPhase,
  setPrejoinKind
}: {
  api: CallApi;
  available: boolean;
  conversationId: string;
  currentCallId?: string;
  currentMediaKind: CallMediaKind;
  disconnectEndedCall: (room: Room, kind: CallMediaKind) => Promise<void>;
  latestRealtimeEventRef: MutableRefObject<CallRealtimeEvent | null>;
  accessRevokedRef: MutableRefObject<boolean>;
  operationIsCurrent: (generation: number) => boolean;
  operationGenerationRef: MutableRefObject<number>;
  phase: CallPhase;
  roomRef: MutableRefObject<Room | null>;
  refreshSequenceRef: MutableRefObject<number>;
  setCall: (call: Call | null) => void;
  setError: (error: string | null) => void;
  setPhase: (
    value: CallPhase | ((current: CallPhase) => CallPhase)
  ) => void;
  setPrejoinKind: (kind: CallMediaKind) => void;
}) {
  const refreshCall = useCallback(
    async (preservePrejoin = false) => {
      if (!available || accessRevokedRef.current || roomRef.current) return;
      const generation = operationGenerationRef.current;
      const refreshSequence = ++refreshSequenceRef.current;
      try {
        const activeCall = await getCall(api, conversationId);
        if (
          !operationIsCurrent(generation) ||
          refreshSequenceRef.current !== refreshSequence ||
          roomRef.current
        ) {
          return;
        }
        const latestEvent = latestRealtimeEventRef.current;
        if (latestEvent?.conversation_id === conversationId) {
          if (
            latestEvent.status === "ended" &&
            (!activeCall || activeCall.id === latestEvent.id)
          ) {
            return;
          }
          if (latestEvent.status === "active" && !activeCall) return;
        }
        setCall(activeCall?.status === "active" ? activeCall : null);
        if (activeCall) setPrejoinKind(callMediaKind(activeCall));
        setError(null);
        setPhase((current) =>
          preservePrejoin &&
          (current === "prejoin" || current === "joining")
            ? current
            : "idle"
        );
      } catch (reason: unknown) {
        if (
          !operationIsCurrent(generation) ||
          refreshSequenceRef.current !== refreshSequence
        ) {
          return;
        }
        setError(`Call status is unavailable. ${errorText(reason)}`);
        setPhase("error");
      }
    },
    [
      api,
      accessRevokedRef,
      available,
      conversationId,
      latestRealtimeEventRef,
      operationGenerationRef,
      operationIsCurrent,
      roomRef,
      setCall,
      setError,
      setPhase,
      setPrejoinKind
    ]
  );

  useEffect(() => {
    if (!available) return;
    const refreshIfIdle = () => {
      if (
        document.visibilityState === "visible" &&
        !roomRef.current &&
        phase !== "prejoin" &&
        phase !== "joining"
      ) {
        void refreshCall();
      }
    };
    const timer = window.setInterval(refreshIfIdle, 15_000);
    window.addEventListener("focus", refreshIfIdle);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refreshIfIdle);
    };
  }, [available, phase, refreshCall, roomRef]);

  useEffect(() => {
    if (
      (phase !== "connected" && phase !== "reconnecting") ||
      !currentCallId
    ) {
      return;
    }
    let current = true;
    let checking = false;

    const verifyActiveCall = async () => {
      const room = roomRef.current;
      if (!current || checking || !room) return;
      checking = true;
      try {
        const activeCall = await getCall(api, conversationId);
        if (!current || roomRef.current !== room) return;
        if (
          activeCall?.id === currentCallId &&
          activeCall.status === "active"
        ) {
          setCall(activeCall);
          return;
        }

        await disconnectEndedCall(room, currentMediaKind);
      } catch {
        // The media provider remains authoritative during a transient API
        // failure. Its disconnect/revocation events still tear down capture.
      } finally {
        checking = false;
      }
    };

    const verifyWhenVisible = () => {
      if (document.visibilityState === "visible") void verifyActiveCall();
    };
    const timer = window.setInterval(verifyWhenVisible, 15_000);
    window.addEventListener("focus", verifyWhenVisible);
    document.addEventListener("visibilitychange", verifyWhenVisible);
    return () => {
      current = false;
      window.clearInterval(timer);
      window.removeEventListener("focus", verifyWhenVisible);
      document.removeEventListener("visibilitychange", verifyWhenVisible);
    };
  }, [
    api,
    conversationId,
    currentCallId,
    currentMediaKind,
    disconnectEndedCall,
    phase,
    roomRef,
    setCall
  ]);

  return {
    refreshCall
  };
}
