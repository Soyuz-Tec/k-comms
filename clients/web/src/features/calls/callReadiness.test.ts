import { describe, expect, it } from "vitest";
import type { Room } from "livekit-client";
import {
  buildCallReadinessReport,
  collectCallReadinessMetrics,
  evaluateCallReadiness,
  initialCallReadinessChecks,
  type CallReadinessCheckResult,
  type CallReadinessMetrics
} from "./callReadiness";

const passingMetrics: CallReadinessMetrics = {
  sampled_at: "2026-08-06T12:00:00.000Z",
  region: "me-central-1",
  transport: "turn-tls",
  candidate_type: "relay",
  protocol: "tls",
  codec: "audio/opus",
  outbound_packets: 600,
  inbound_packets: 590,
  packets_lost: 2,
  packet_loss_percent: 0.34,
  jitter_ms: 18,
  round_trip_time_ms: 122
};

function passedChecks() {
  return initialCallReadinessChecks().map<CallReadinessCheckResult>(
    (check) => ({ ...check, status: "passed" })
  );
}

describe("call readiness evaluation", () => {
  it("passes only a two-way TLS relay call with audible confirmation", () => {
    expect(evaluateCallReadiness({
      checks: passedChecks(),
      completed: true,
      heardPeer: true,
      metrics: passingMetrics,
      tlsRelaySwitchSucceeded: true,
      unexpectedReconnects: 0
    })).toEqual({ verdict: "pass", reasons: [] });
  });

  it("fails closed when any required preflight is incomplete", () => {
    const checks = passedChecks();
    checks[2] = { ...checks[2]!, status: "idle" };

    const result = evaluateCallReadiness({
      checks,
      completed: true,
      heardPeer: true,
      metrics: passingMetrics,
      tlsRelaySwitchSucceeded: true,
      unexpectedReconnects: 0
    });

    expect(result.verdict).toBe("fail");
    expect(result.reasons).toContain(
      "One or more required signaling, relay, microphone, or recovery checks did not pass."
    );
  });

  it("warns when quality thresholds are exceeded", () => {
    const result = evaluateCallReadiness({
      checks: passedChecks(),
      completed: true,
      heardPeer: true,
      metrics: {
        ...passingMetrics,
        packet_loss_percent: 3.01,
        jitter_ms: 50.01,
        round_trip_time_ms: 400.01
      },
      tlsRelaySwitchSucceeded: true,
      unexpectedReconnects: 1
    });

    expect(result.verdict).toBe("warning");
    expect(result.reasons).toHaveLength(4);
  });

  it("fails a direct or one-way call even when its quality is otherwise good", () => {
    const result = evaluateCallReadiness({
      checks: passedChecks(),
      completed: true,
      heardPeer: false,
      metrics: {
        ...passingMetrics,
        candidate_type: "host",
        protocol: "udp",
        transport: "direct",
        inbound_packets: 0
      },
      tlsRelaySwitchSucceeded: true,
      unexpectedReconnects: 0
    });

    expect(result.verdict).toBe("fail");
    expect(result.reasons).toEqual(expect.arrayContaining([
      "The selected candidate was not verified as a TCP/TLS relay path.",
      "No inbound office audio packets were observed.",
      "Audible speech was not confirmed on this device."
    ]));
  });

  it("exports only the bounded, privacy-safe report schema", () => {
    const report = buildCallReadinessReport({
      checks: passedChecks(),
      evaluation: { verdict: "pass", reasons: [] },
      heardPeer: true,
      metrics: passingMetrics,
      tlsRelaySwitchSucceeded: true,
      unexpectedReconnects: 0
    });
    const serialized = JSON.stringify(report);

    expect(report.schema).toBe("k-comms.call-readiness.v1");
    expect(report.privacy).toEqual({
      audio_recorded: false,
      network_addresses_included: false,
      credentials_included: false
    });
    expect(serialized).not.toContain("participant_token");
    expect(serialized).not.toContain("room_id");
    expect(serialized).not.toContain("ip_address");
  });
});

describe("call readiness media metrics", () => {
  it("reduces browser RTC stats to aggregate audio and transport metrics", async () => {
    const report = new Map<string, Record<string, unknown>>([
      ["outbound", { id: "outbound", type: "outbound-rtp", kind: "audio", packetsSent: 321, codecId: "codec" }],
      ["inbound", { id: "inbound", type: "inbound-rtp", kind: "audio", packetsReceived: 300, packetsLost: 3, jitter: 0.018, codecId: "codec" }],
      ["remote-inbound", { id: "remote-inbound", type: "remote-inbound-rtp", kind: "audio", roundTripTime: 0.125 }],
      ["transport", { id: "transport", type: "transport", selectedCandidatePairId: "pair" }],
      ["pair", { id: "pair", type: "candidate-pair", nominated: true, currentRoundTripTime: 0.13, localCandidateId: "local" }],
      ["local", { id: "local", type: "local-candidate", candidateType: "relay", relayProtocol: "tls", address: "192.0.2.1" }],
      ["codec", { id: "codec", type: "codec", mimeType: "audio/opus" }]
    ]);
    const room = {
      localParticipant: {
        getTrackPublication: () => ({
          track: { getRTCStatsReport: async () => report as unknown as RTCStatsReport }
        })
      },
      remoteParticipants: new Map(),
      serverInfo: { region: "me-central-1" }
    } as unknown as Room;

    const metrics = await collectCallReadinessMetrics(room);

    expect(metrics).toMatchObject({
      region: "me-central-1",
      transport: "turn-tls",
      candidate_type: "relay",
      protocol: "tls",
      codec: "audio/opus",
      outbound_packets: 321,
      inbound_packets: 300,
      packets_lost: 3,
      packet_loss_percent: 0.99,
      jitter_ms: 18,
      round_trip_time_ms: 130
    });
    expect(metrics).not.toHaveProperty("address");
  });
});
