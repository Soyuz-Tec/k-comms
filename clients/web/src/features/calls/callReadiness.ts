import {
  CheckStatus,
  ConnectionCheck,
  RoomEvent,
  Track,
  type CheckInfo,
  type Room
} from "livekit-client";

export const CALL_READINESS_DURATION_SECONDS = 60;

export type CallReadinessCheckStatus =
  | "idle"
  | "running"
  | "passed"
  | "failed"
  | "skipped";

export interface CallReadinessCheckResult {
  id: "websocket" | "turn" | "microphone" | "reconnect";
  label: string;
  status: CallReadinessCheckStatus;
}

export interface CallReadinessMetrics {
  sampled_at: string;
  region: string | null;
  transport: "turn-tls" | "turn-tcp" | "turn-udp" | "relay" | "direct" | "unknown";
  candidate_type: "relay" | "host" | "srflx" | "prflx" | "unknown";
  protocol: "tls" | "tcp" | "udp" | "unknown";
  codec: string | null;
  outbound_packets: number;
  inbound_packets: number;
  packets_lost: number;
  packet_loss_percent: number | null;
  jitter_ms: number | null;
  round_trip_time_ms: number | null;
}

export type CallReadinessVerdict = "pending" | "pass" | "warning" | "fail";

export interface CallReadinessEvaluation {
  verdict: CallReadinessVerdict;
  reasons: string[];
}

export interface CallReadinessReport {
  schema: "k-comms.call-readiness.v1";
  generated_at: string;
  test: "uae-office-audio";
  duration_seconds: number;
  result: CallReadinessEvaluation;
  checks: CallReadinessCheckResult[];
  tls_relay_requested: boolean;
  tls_relay_switch_succeeded: boolean;
  heard_peer: boolean;
  unexpected_reconnects: number;
  metrics: CallReadinessMetrics | null;
  privacy: {
    audio_recorded: false;
    network_addresses_included: false;
    credentials_included: false;
  };
}

const preflightChecks: Array<{
  id: CallReadinessCheckResult["id"];
  label: string;
  run: (check: ConnectionCheck) => Promise<CheckInfo>;
}> = [
  {
    id: "websocket",
    label: "Secure signaling",
    run: (check) => check.checkWebsocket()
  },
  {
    id: "turn",
    label: "TURN relay",
    run: (check) => check.checkTURN()
  },
  {
    id: "microphone",
    label: "Relay microphone publish",
    run: (check) => check.checkPublishAudio()
  },
  {
    id: "reconnect",
    label: "Connection recovery",
    run: (check) => check.checkReconnect()
  }
];

export function initialCallReadinessChecks(): CallReadinessCheckResult[] {
  return preflightChecks.map(({ id, label }) => ({ id, label, status: "idle" }));
}

export async function runCallReadinessPreflight(
  serverUrl: string,
  participantToken: string,
  onUpdate: (results: CallReadinessCheckResult[]) => void
): Promise<CallReadinessCheckResult[]> {
  const connectionCheck = new ConnectionCheck(serverUrl, participantToken, {
    connectOptions: {
      rtcConfig: { iceTransportPolicy: "relay" }
    }
  });
  let results = initialCallReadinessChecks();
  onUpdate(results);

  for (const definition of preflightChecks) {
    results = updateCheck(results, definition.id, "running");
    onUpdate(results);
    try {
      const info = await definition.run(connectionCheck);
      results = updateCheck(results, definition.id, checkStatus(info.status));
    } catch {
      results = updateCheck(results, definition.id, "failed");
    }
    onUpdate(results);
  }

  return results;
}

function updateCheck(
  values: CallReadinessCheckResult[],
  id: CallReadinessCheckResult["id"],
  status: CallReadinessCheckStatus
): CallReadinessCheckResult[] {
  return values.map((value) => value.id === id ? { ...value, status } : value);
}

function checkStatus(value: CheckStatus): CallReadinessCheckStatus {
  if (value === CheckStatus.SUCCESS) return "passed";
  if (value === CheckStatus.FAILED) return "failed";
  if (value === CheckStatus.SKIPPED) return "skipped";
  if (value === CheckStatus.RUNNING) return "running";
  return "idle";
}

export async function requestTurnTlsTransport(
  room: Room,
  timeoutMs = 15_000
): Promise<boolean> {
  let reconnecting = false;
  let settled = false;
  let resolveReconnect: ((value: boolean) => void) | null = null;
  const reconnected = new Promise<boolean>((resolve) => {
    resolveReconnect = resolve;
  });
  const onReconnecting = () => {
    reconnecting = true;
  };
  const onReconnected = () => {
    if (settled) return;
    settled = true;
    resolveReconnect?.(true);
  };
  room.on(RoomEvent.Reconnecting, onReconnecting);
  room.on(RoomEvent.Reconnected, onReconnected);

  try {
    await room.simulateScenario("force-tls");
    await delay(1_000);
    if (!reconnecting) return true;
    return await Promise.race([
      reconnected,
      delay(timeoutMs).then(() => false)
    ]);
  } finally {
    settled = true;
    room.off(RoomEvent.Reconnecting, onReconnecting);
    room.off(RoomEvent.Reconnected, onReconnected);
  }
}

export async function collectCallReadinessMetrics(
  room: Room
): Promise<CallReadinessMetrics> {
  const reports: RTCStatsReport[] = [];
  const localMicrophone = room.localParticipant.getTrackPublication(Track.Source.Microphone)?.track;
  if (localMicrophone) {
    const report = await localMicrophone.getRTCStatsReport();
    if (report) reports.push(report);
  }
  for (const participant of room.remoteParticipants.values()) {
    for (const publication of participant.audioTrackPublications.values()) {
      if (!publication.track) continue;
      const report = await publication.track.getRTCStatsReport();
      if (report) reports.push(report);
    }
  }

  const stats = mergedStats(reports);
  let outboundPackets = 0;
  let inboundPackets = 0;
  let packetsLost = 0;
  const jitters: number[] = [];
  const roundTrips: number[] = [];
  let codec: string | null = null;
  const pair = currentCandidatePair(stats);

  for (const value of stats.values()) {
    if (value.type === "outbound-rtp" && audioStat(value)) {
      outboundPackets += safeNumber(value.packetsSent);
      codec ||= codecName(stats, value.codecId);
    }
    if (value.type === "inbound-rtp" && audioStat(value)) {
      inboundPackets += safeNumber(value.packetsReceived);
      packetsLost += Math.max(0, safeNumber(value.packetsLost));
      if (finiteNumber(value.jitter)) jitters.push(value.jitter * 1_000);
      codec ||= codecName(stats, value.codecId);
    }
    if (value.type === "remote-inbound-rtp" && audioStat(value)) {
      if (finiteNumber(value.roundTripTime)) roundTrips.push(value.roundTripTime * 1_000);
      if (finiteNumber(value.jitter)) jitters.push(value.jitter * 1_000);
    }
  }
  if (pair && finiteNumber(pair.currentRoundTripTime)) {
    roundTrips.push(pair.currentRoundTripTime * 1_000);
  }

  const localCandidate = pair?.localCandidateId
    ? stats.get(String(pair.localCandidateId))
    : undefined;
  const candidateType = candidateTypeValue(localCandidate?.candidateType);
  const protocol = protocolValue(localCandidate?.relayProtocol || localCandidate?.protocol);
  const packetTotal = inboundPackets + packetsLost;

  return {
    sampled_at: new Date().toISOString(),
    region: room.serverInfo?.region || null,
    transport: transportValue(candidateType, protocol),
    candidate_type: candidateType,
    protocol,
    codec,
    outbound_packets: outboundPackets,
    inbound_packets: inboundPackets,
    packets_lost: packetsLost,
    packet_loss_percent: packetTotal > 0
      ? round((packetsLost / packetTotal) * 100)
      : null,
    jitter_ms: maximum(jitters),
    round_trip_time_ms: maximum(roundTrips)
  };
}

export function evaluateCallReadiness({
  checks,
  completed,
  heardPeer,
  metrics,
  tlsRelaySwitchSucceeded,
  unexpectedReconnects
}: {
  checks: CallReadinessCheckResult[];
  completed: boolean;
  heardPeer: boolean;
  metrics: CallReadinessMetrics | null;
  tlsRelaySwitchSucceeded: boolean;
  unexpectedReconnects: number;
}): CallReadinessEvaluation {
  if (!completed) return { verdict: "pending", reasons: [] };

  const failures: string[] = [];
  if (checks.some(({ status }) => status !== "passed")) {
    failures.push("One or more required signaling, relay, microphone, or recovery checks did not pass.");
  }
  if (!tlsRelaySwitchSucceeded) failures.push("TURN/TLS switching did not complete.");
  if (
    !metrics
    || metrics.candidate_type !== "relay"
    || (metrics.protocol !== "tls" && metrics.protocol !== "tcp")
  ) {
    failures.push("The selected candidate was not verified as a TCP/TLS relay path.");
  }
  if (!metrics || metrics.outbound_packets === 0) {
    failures.push("No outbound microphone packets were observed.");
  }
  if (!metrics || metrics.inbound_packets === 0) {
    failures.push("No inbound office audio packets were observed.");
  }
  if (!heardPeer) failures.push("Audible speech was not confirmed on this device.");
  if (failures.length > 0) return { verdict: "fail", reasons: failures };

  const warnings: string[] = [];
  if ((metrics?.packet_loss_percent || 0) > 3) warnings.push("Packet loss exceeded 3%.");
  if ((metrics?.jitter_ms || 0) > 50) warnings.push("Jitter exceeded 50 ms.");
  if ((metrics?.round_trip_time_ms || 0) > 400) warnings.push("Round-trip time exceeded 400 ms.");
  if (unexpectedReconnects > 0) warnings.push("The call reconnected during the measurement window.");

  return {
    verdict: warnings.length > 0 ? "warning" : "pass",
    reasons: warnings
  };
}

export function buildCallReadinessReport({
  checks,
  evaluation,
  heardPeer,
  metrics,
  tlsRelaySwitchSucceeded,
  unexpectedReconnects
}: {
  checks: CallReadinessCheckResult[];
  evaluation: CallReadinessEvaluation;
  heardPeer: boolean;
  metrics: CallReadinessMetrics | null;
  tlsRelaySwitchSucceeded: boolean;
  unexpectedReconnects: number;
}): CallReadinessReport {
  return {
    schema: "k-comms.call-readiness.v1",
    generated_at: new Date().toISOString(),
    test: "uae-office-audio",
    duration_seconds: CALL_READINESS_DURATION_SECONDS,
    result: evaluation,
    checks,
    tls_relay_requested: true,
    tls_relay_switch_succeeded: tlsRelaySwitchSucceeded,
    heard_peer: heardPeer,
    unexpected_reconnects: unexpectedReconnects,
    metrics,
    privacy: {
      audio_recorded: false,
      network_addresses_included: false,
      credentials_included: false
    }
  };
}

export function downloadCallReadinessReport(report: CallReadinessReport): void {
  const blob = new Blob([`${JSON.stringify(report, null, 2)}\n`], {
    type: "application/json"
  });
  const href = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = href;
  link.download = `k-comms-call-readiness-${report.generated_at.replace(/[:.]/g, "-")}.json`;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(href), 0);
}

type AnyRtcStats = RTCStats & Record<string, unknown>;

function mergedStats(reports: RTCStatsReport[]): Map<string, AnyRtcStats> {
  const values = new Map<string, AnyRtcStats>();
  reports.forEach((report) => report.forEach((value) => values.set(value.id, value as AnyRtcStats)));
  return values;
}

function audioStat(value: AnyRtcStats): boolean {
  return value.kind === "audio" || (!value.kind && value.mediaType === "audio");
}

function codecName(stats: Map<string, AnyRtcStats>, codecId: unknown): string | null {
  if (typeof codecId !== "string") return null;
  const value = stats.get(codecId);
  return typeof value?.mimeType === "string" ? value.mimeType : null;
}

function currentCandidatePair(stats: Map<string, AnyRtcStats>): AnyRtcStats | undefined {
  for (const value of stats.values()) {
    if (value.type !== "transport" || typeof value.selectedCandidatePairId !== "string") {
      continue;
    }
    const selected = stats.get(value.selectedCandidatePairId);
    if (selected?.type === "candidate-pair") return selected;
  }

  return [...stats.values()]
    .filter((value) => (
      value.type === "candidate-pair"
      && (value.selected === true || value.nominated === true)
      && value.state !== "failed"
    ))
    .sort((left, right) => safeNumber(right.timestamp) - safeNumber(left.timestamp))[0];
}

function candidateTypeValue(value: unknown): CallReadinessMetrics["candidate_type"] {
  return value === "relay" || value === "host" || value === "srflx" || value === "prflx"
    ? value
    : "unknown";
}

function protocolValue(value: unknown): CallReadinessMetrics["protocol"] {
  if (value === "tls") return "tls";
  if (value === "tcp") return "tcp";
  return value === "udp" ? "udp" : "unknown";
}

function transportValue(
  candidateType: CallReadinessMetrics["candidate_type"],
  protocol: CallReadinessMetrics["protocol"]
): CallReadinessMetrics["transport"] {
  if (candidateType !== "relay") return candidateType === "unknown" ? "unknown" : "direct";
  if (protocol === "udp") return "turn-udp";
  if (protocol === "tls") return "turn-tls";
  if (protocol === "tcp") return "turn-tcp";
  return "relay";
}

function safeNumber(value: unknown): number {
  return finiteNumber(value) ? value : 0;
}

function finiteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function maximum(values: number[]): number | null {
  return values.length > 0 ? round(Math.max(...values)) : null;
}

function round(value: number): number {
  return Math.round(value * 100) / 100;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}
