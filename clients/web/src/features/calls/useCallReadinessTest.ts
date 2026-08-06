import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MutableRefObject
} from "react";
import type { Room } from "livekit-client";
import type { ParticipantView } from "./CallPanelViews";
import {
  CALL_READINESS_DURATION_SECONDS,
  buildCallReadinessReport,
  collectCallReadinessMetrics,
  evaluateCallReadiness,
  initialCallReadinessChecks,
  requestTurnTlsTransport,
  runCallReadinessPreflight,
  type CallReadinessCheckResult,
  type CallReadinessEvaluation,
  type CallReadinessMetrics
} from "./callReadiness";

export type CallReadinessPhase =
  | "idle"
  | "preflight"
  | "switching_transport"
  | "waiting_for_peer"
  | "measuring"
  | "complete"
  | "failed";

const pendingEvaluation: CallReadinessEvaluation = {
  verdict: "pending",
  reasons: []
};

export function useCallReadinessTest({
  microphoneEnabled,
  participants,
  roomRef
}: {
  microphoneEnabled: boolean;
  participants: ParticipantView[];
  roomRef: MutableRefObject<Room | null>;
}) {
  const [enabled, setEnabledState] = useState(false);
  const [phase, setPhaseState] = useState<CallReadinessPhase>("idle");
  const [checks, setChecks] = useState<CallReadinessCheckResult[]>(
    initialCallReadinessChecks
  );
  const [secondsRemaining, setSecondsRemaining] = useState(
    CALL_READINESS_DURATION_SECONDS
  );
  const [metrics, setMetrics] = useState<CallReadinessMetrics | null>(null);
  const [tlsRelaySwitchSucceeded, setTlsRelaySwitchSucceeded] = useState(false);
  const [heardPeer, setHeardPeer] = useState(false);
  const [unexpectedReconnects, setUnexpectedReconnects] = useState(0);
  const [failure, setFailure] = useState<string | null>(null);
  const [evaluation, setEvaluation] = useState<CallReadinessEvaluation>(pendingEvaluation);
  const phaseRef = useRef<CallReadinessPhase>("idle");
  const generationRef = useRef(0);
  const timerRef = useRef<number | null>(null);
  const measurementStartedAtRef = useRef<number | null>(null);

  const setPhase = useCallback((value: CallReadinessPhase) => {
    phaseRef.current = value;
    setPhaseState(value);
  }, []);

  const clearTimer = useCallback(() => {
    if (timerRef.current !== null) window.clearInterval(timerRef.current);
    timerRef.current = null;
  }, []);

  const reset = useCallback((nextEnabled = false) => {
    generationRef.current += 1;
    clearTimer();
    setEnabledState(nextEnabled);
    setPhase("idle");
    setChecks(initialCallReadinessChecks());
    setSecondsRemaining(CALL_READINESS_DURATION_SECONDS);
    setMetrics(null);
    setTlsRelaySwitchSucceeded(false);
    setHeardPeer(false);
    setUnexpectedReconnects(0);
    setFailure(null);
    setEvaluation(pendingEvaluation);
    measurementStartedAtRef.current = null;
  }, [clearTimer, setPhase]);

  const setEnabled = useCallback((value: boolean) => reset(value), [reset]);

  const runPreflight = useCallback(async (serverUrl: string, participantToken: string) => {
    if (!enabled) return initialCallReadinessChecks();
    const generation = ++generationRef.current;
    setFailure(null);
    setPhase("preflight");
    const results = await runCallReadinessPreflight(
      serverUrl,
      participantToken,
      (next) => {
        if (generationRef.current === generation) setChecks(next);
      }
    );
    if (generationRef.current === generation) setChecks(results);
    return results;
  }, [enabled, setPhase]);

  const beginTransportQualification = useCallback(async (room: Room) => {
    if (!enabled) return;
    const generation = generationRef.current;
    setPhase("switching_transport");
    let succeeded: boolean;
    try {
      succeeded = await requestTurnTlsTransport(room);
    } catch {
      succeeded = false;
    }
    if (generationRef.current !== generation || roomRef.current !== room) return;
    setTlsRelaySwitchSucceeded(succeeded);
    if (!succeeded) {
      setFailure("K-Comms could not confirm the TURN/TLS transport switch.");
    }
    setPhase("waiting_for_peer");
  }, [enabled, roomRef, setPhase]);

  const fail = useCallback((message: string) => {
    clearTimer();
    setFailure(message);
    setPhase("failed");
    setEvaluation({ verdict: "fail", reasons: [message] });
  }, [clearTimer, setPhase]);

  const recordUnexpectedReconnect = useCallback(() => {
    if (phaseRef.current === "measuring") {
      setUnexpectedReconnects((value) => value + 1);
    }
  }, []);

  useEffect(() => {
    if (!enabled || phase !== "waiting_for_peer") return;
    const hasRemoteParticipant = participants.some((participant) => !participant.local);
    if (!hasRemoteParticipant || !microphoneEnabled || !roomRef.current) return;

    setFailure(null);
    setSecondsRemaining(CALL_READINESS_DURATION_SECONDS);
    measurementStartedAtRef.current = Date.now();
    setPhase("measuring");
  }, [enabled, microphoneEnabled, participants, phase, roomRef, setPhase]);

  useEffect(() => {
    if (!enabled || phase !== "measuring" || !roomRef.current) return;

    const room = roomRef.current;
    const generation = generationRef.current;
    const startedAt = measurementStartedAtRef.current || Date.now();
    measurementStartedAtRef.current = startedAt;

    const sample = async () => {
      try {
        const nextMetrics = await collectCallReadinessMetrics(room);
        if (generationRef.current === generation && roomRef.current === room) {
          setMetrics(nextMetrics);
        }
      } catch {
        // A missing sample is represented as an incomplete report. The final
        // sample determines the result without exposing browser internals.
      }
    };
    void sample();

    timerRef.current = window.setInterval(() => {
      if (generationRef.current !== generation || roomRef.current !== room) {
        clearTimer();
        return;
      }
      const elapsedSeconds = Math.floor((Date.now() - startedAt) / 1_000);
      const remaining = Math.max(0, CALL_READINESS_DURATION_SECONDS - elapsedSeconds);
      setSecondsRemaining(remaining);
      if (elapsedSeconds > 0 && elapsedSeconds % 5 === 0) void sample();
      if (remaining > 0) return;

      clearTimer();
      void collectCallReadinessMetrics(room)
        .then((finalMetrics) => {
          if (generationRef.current !== generation || roomRef.current !== room) return;
          setMetrics(finalMetrics);
          setPhase("complete");
        })
        .catch(() => {
          if (generationRef.current === generation) {
            fail("The browser did not expose a complete media statistics sample.");
          }
        });
    }, 1_000);

    return clearTimer;
  }, [
    clearTimer,
    enabled,
    fail,
    phase,
    roomRef,
    setPhase
  ]);

  useEffect(() => {
    if (phase !== "complete") return;
    setEvaluation(evaluateCallReadiness({
      checks,
      completed: true,
      heardPeer,
      metrics,
      tlsRelaySwitchSucceeded,
      unexpectedReconnects
    }));
  }, [
    checks,
    heardPeer,
    metrics,
    phase,
    tlsRelaySwitchSucceeded,
    unexpectedReconnects
  ]);

  useEffect(() => () => {
    generationRef.current += 1;
    clearTimer();
  }, [clearTimer]);

  const report = useMemo(() => (
    (phase === "complete" || phase === "failed")
    && evaluation.verdict !== "pending"
  )
    ? buildCallReadinessReport({
        checks,
        evaluation,
        heardPeer,
        metrics,
        tlsRelaySwitchSucceeded,
        unexpectedReconnects
      })
    : null,
  [
    checks,
    evaluation,
    heardPeer,
    metrics,
    phase,
    tlsRelaySwitchSucceeded,
    unexpectedReconnects
  ]);

  return {
    beginTransportQualification,
    checks,
    enabled,
    evaluation,
    fail,
    failure,
    heardPeer,
    metrics,
    phase,
    recordUnexpectedReconnect,
    report,
    reset,
    runPreflight,
    secondsRemaining,
    setEnabled,
    setHeardPeer,
    tlsRelaySwitchSucceeded,
    unexpectedReconnects
  };
}

export type CallReadinessTestState = ReturnType<typeof useCallReadinessTest>;
