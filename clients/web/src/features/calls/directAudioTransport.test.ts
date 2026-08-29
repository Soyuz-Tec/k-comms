import { describe, expect, it, vi } from "vitest";
import {
  DirectAudioTransport,
  type DirectAudioSignal,
  type DirectAudioTransportState
} from "./directAudioTransport";

const AUDIO_SDP = [
  "v=0",
  "o=- 0 0 IN IP4 127.0.0.1",
  "s=-",
  "t=0 0",
  "m=audio 9 UDP/TLS/RTP/SAVPF 111",
  "a=ice-ufrag:abcd",
  "a=ice-pwd:abcdefghijklmnopqrstuv",
  "a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00",
  "a=setup:actpass",
  "a=rtcp-mux",
  ""
].join("\r\n");

class FakePeerConnection {
  connectionState: RTCPeerConnectionState = "new";
  remoteDescription: RTCSessionDescription | null = null;
  localDescription: RTCSessionDescription | null = null;
  onicecandidate: RTCPeerConnection["onicecandidate"] = null;
  ontrack: RTCPeerConnection["ontrack"] = null;
  ondatachannel: RTCPeerConnection["ondatachannel"] = null;
  onconnectionstatechange: RTCPeerConnection["onconnectionstatechange"] = null;
  sender = {
    track: null as MediaStreamTrack | null,
    replaceTrack: vi.fn(async (track: MediaStreamTrack | null) => {
      this.sender.track = track;
    })
  };
  addTransceiver = vi.fn();
  createOffer = vi.fn(async () => ({ type: "offer", sdp: AUDIO_SDP } as RTCSessionDescriptionInit));
  createAnswer = vi.fn(async () => ({ type: "answer", sdp: AUDIO_SDP } as RTCSessionDescriptionInit));
  setLocalDescription = vi.fn(async (description: RTCSessionDescriptionInit) => {
    this.localDescription = description as RTCSessionDescription;
  });
  setRemoteDescription = vi.fn(async (description: RTCSessionDescriptionInit) => {
    this.remoteDescription = description as RTCSessionDescription;
  });
  addIceCandidate = vi.fn(async () => undefined);
  stats = new Map<string, unknown>();
  getStats = vi.fn(async () => this.stats as unknown as RTCStatsReport);
  getSenders = vi.fn(() => [this.sender]);
  close = vi.fn(() => {
    this.connectionState = "closed";
  });
}

function microphoneTrack() {
  return {
    kind: "audio",
    enabled: true,
    stop: vi.fn()
  } as unknown as MediaStreamTrack;
}

function microphoneStream(track: MediaStreamTrack) {
  return {
    getAudioTracks: () => [track],
    getTracks: () => [track]
  } as unknown as MediaStream;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolver) => { resolve = resolver; });
  return { promise, resolve };
}

describe("DirectAudioTransport", () => {
  it("creates a deterministic offer and controls a direct microphone track", async () => {
    const peer = new FakePeerConnection();
    const signals: DirectAudioSignal[] = [];
    const states: DirectAudioTransportState[] = [];
    const track = microphoneTrack();
    const getUserMedia = vi.fn(async () => microphoneStream(track));
    const transport = new DirectAudioTransport({
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
      audioHost: document.body,
      onSignal: (signal) => signals.push(signal),
      onState: (state) => states.push(state),
      peerConnectionFactory: () => peer as unknown as RTCPeerConnection,
      getUserMedia
    });

    await transport.start("a-local-peer", "z-remote-peer", false, "microphone-1");
    expect(peer.addTransceiver).toHaveBeenCalledWith("audio", { direction: "sendrecv" });
    expect(signals).toContainEqual({ kind: "offer", sdp: AUDIO_SDP });
    expect(getUserMedia).not.toHaveBeenCalled();

    await transport.setMicrophoneEnabled(true);
    expect(getUserMedia).toHaveBeenCalledWith({
      audio: { deviceId: { exact: "microphone-1" } },
      video: false
    });
    expect(peer.sender.track).toBe(track);

    await transport.setMicrophoneEnabled(false);
    expect(track.enabled).toBe(false);
    peer.connectionState = "connected";
    (peer.onconnectionstatechange as ((event: Event) => void) | null)?.(
      new Event("connectionstatechange")
    );
    expect(states).toContain("connected");

    transport.stop();
    expect(track.stop).toHaveBeenCalled();
    expect(peer.close).toHaveBeenCalled();
  });

  it("queues ICE until an offer arrives and answers without persisting signaling", async () => {
    const peer = new FakePeerConnection();
    const signals: DirectAudioSignal[] = [];
    const transport = new DirectAudioTransport({
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
      audioHost: document.body,
      onSignal: (signal) => signals.push(signal),
      onState: vi.fn(),
      peerConnectionFactory: () => peer as unknown as RTCPeerConnection
    });

    await transport.start("z-local-peer", "a-remote-peer", false, "");
    expect(peer.createOffer).not.toHaveBeenCalled();
    await transport.handleSignal({
      kind: "ice",
      candidate: "candidate:1 1 udp 1 192.0.2.1 5000 typ host",
      sdp_mid: "0",
      sdp_mline_index: 0
    });
    expect(peer.addIceCandidate).not.toHaveBeenCalled();

    await transport.handleSignal({ kind: "offer", sdp: AUDIO_SDP });
    expect(peer.setRemoteDescription).toHaveBeenCalledWith({ type: "offer", sdp: AUDIO_SDP });
    expect(peer.addIceCandidate).toHaveBeenCalledTimes(1);
    expect(signals).toContainEqual({ kind: "answer", sdp: AUDIO_SDP });
    transport.stop();
  });

  it("stops a microphone acquired after the transport was stopped", async () => {
    const peer = new FakePeerConnection();
    const pendingStream = deferred<MediaStream>();
    const track = microphoneTrack();
    const transport = new DirectAudioTransport({
      iceServers: [],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: vi.fn(),
      peerConnectionFactory: () => peer as unknown as RTCPeerConnection,
      getUserMedia: () => pendingStream.promise
    });

    await transport.start("z-local-peer", "a-remote-peer", false, "");
    const enabling = transport.setMicrophoneEnabled(true);
    transport.stop();
    pendingStream.resolve(microphoneStream(track));
    await enabling;

    expect(track.stop).toHaveBeenCalledTimes(1);
    expect(peer.sender.replaceTrack).not.toHaveBeenCalled();
  });

  it("stops an acquired microphone when sender replacement fails", async () => {
    const peer = new FakePeerConnection();
    peer.sender.replaceTrack.mockRejectedValueOnce(new Error("replacement failed"));
    const track = microphoneTrack();
    const transport = new DirectAudioTransport({
      iceServers: [],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: vi.fn(),
      peerConnectionFactory: () => peer as unknown as RTCPeerConnection,
      getUserMedia: async () => microphoneStream(track)
    });

    await transport.start("z-local-peer", "a-remote-peer", false, "");
    await expect(transport.setMicrophoneEnabled(true)).rejects.toThrow("replacement failed");
    expect(track.stop).toHaveBeenCalledTimes(1);
    transport.stop();
  });

  it("rejects descriptions with video or application media", async () => {
    for (const media of ["video", "application"]) {
      const peer = new FakePeerConnection();
      const states: DirectAudioTransportState[] = [];
      const transport = new DirectAudioTransport({
        iceServers: [],
        audioHost: document.body,
        onSignal: vi.fn(),
        onState: (state) => states.push(state),
        peerConnectionFactory: () => peer as unknown as RTCPeerConnection
      });

      await transport.start("z-local-peer", "a-remote-peer", false, "");
      await expect(transport.handleSignal({
        kind: "offer",
        sdp: `v=0\r\nm=${media} 9 UDP/TLS/RTP/SAVPF 96\r\n`
      })).rejects.toThrow("not audio-only");
      expect(peer.setRemoteDescription).not.toHaveBeenCalled();
      expect(peer.close).toHaveBeenCalled();
      expect(states).toContain("failed");
    }
  });

  it("fails closed on unexpected data channels or non-audio tracks", async () => {
    const dataPeer = new FakePeerConnection();
    const dataStates: DirectAudioTransportState[] = [];
    const dataTransport = new DirectAudioTransport({
      iceServers: [],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: (state) => dataStates.push(state),
      peerConnectionFactory: () => dataPeer as unknown as RTCPeerConnection
    });
    await dataTransport.start("z-local-peer", "a-remote-peer", false, "");
    const close = vi.fn();
    (dataPeer.ondatachannel as ((event: RTCDataChannelEvent) => void) | null)?.({
      channel: { close }
    } as unknown as RTCDataChannelEvent);
    expect(close).toHaveBeenCalled();
    expect(dataStates).toContain("failed");

    const trackPeer = new FakePeerConnection();
    const trackStates: DirectAudioTransportState[] = [];
    const trackTransport = new DirectAudioTransport({
      iceServers: [],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: (state) => trackStates.push(state),
      peerConnectionFactory: () => trackPeer as unknown as RTCPeerConnection
    });
    await trackTransport.start("z-local-peer", "a-remote-peer", false, "");
    const stop = vi.fn();
    (trackPeer.ontrack as ((event: RTCTrackEvent) => void) | null)?.({
      track: { kind: "video", stop }
    } as unknown as RTCTrackEvent);
    expect(stop).toHaveBeenCalled();
    expect(trackStates).toContain("failed");
  });

  it("bounds ICE candidates queued before a remote description", async () => {
    const peer = new FakePeerConnection();
    const states: DirectAudioTransportState[] = [];
    const transport = new DirectAudioTransport({
      iceServers: [],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: (state) => states.push(state),
      peerConnectionFactory: () => peer as unknown as RTCPeerConnection
    });
    await transport.start("z-local-peer", "a-remote-peer", false, "");

    for (let index = 0; index < 64; index += 1) {
      await transport.handleSignal({
        kind: "ice",
        candidate: `candidate:${index}`,
        sdp_mid: "0",
        sdp_mline_index: 0
      });
    }

    await expect(transport.handleSignal({
      kind: "ice",
      candidate: "candidate:overflow",
      sdp_mid: "0",
      sdp_mline_index: 0
    })).rejects.toThrow("candidate limit");
    expect(states).toContain("failed");
  });

  it("fails closed when direct ICE does not connect within the bounded window", async () => {
    vi.useFakeTimers();
    try {
      const peer = new FakePeerConnection();
      const states: DirectAudioTransportState[] = [];
      const transport = new DirectAudioTransport({
        iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
        audioHost: document.body,
        onSignal: vi.fn(),
        onState: (state) => states.push(state),
        peerConnectionFactory: () => peer as unknown as RTCPeerConnection
      });

      await transport.start("z-local-peer", "a-remote-peer", false, "");
      await vi.advanceTimersByTimeAsync(12_000);
      expect(states).toContain("failed");
    } finally {
      vi.useRealTimers();
    }
  });
  it("reports only the selected candidate class, never a candidate address", async () => {
    const peer = new FakePeerConnection();
    peer.stats = new Map<string, unknown>([
      ["T1", { id: "T1", type: "transport", selectedCandidatePairId: "P1" }],
      ["P1", { id: "P1", type: "candidate-pair", localCandidateId: "L1", nominated: true, state: "succeeded" }],
      ["L1", { id: "L1", type: "local-candidate", candidateType: "relay", address: "203.0.113.9", port: 51234 }]
    ]);
    const transport = new DirectAudioTransport({
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: vi.fn(),
      peerConnectionFactory: () => peer as unknown as RTCPeerConnection
    });

    await transport.start("a-local-peer", "z-remote-peer", false, "");
    expect(transport.connectDurationMs()).toBeNull();

    peer.connectionState = "connected";
    (peer.onconnectionstatechange as ((event: Event) => void) | null)?.(
      new Event("connectionstatechange")
    );

    await expect(transport.selectedCandidateClass()).resolves.toBe("relay");
    expect(transport.connectDurationMs()).toBeGreaterThanOrEqual(0);
  });

  it("maps a peer-reflexive candidate to the reflexive class and an unknown pair to null", async () => {
    const peer = new FakePeerConnection();
    peer.stats = new Map<string, unknown>([
      ["P1", { id: "P1", type: "candidate-pair", localCandidateId: "L1", nominated: true, state: "succeeded" }],
      ["L1", { id: "L1", type: "local-candidate", candidateType: "prflx" }]
    ]);
    const transport = new DirectAudioTransport({
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: vi.fn(),
      peerConnectionFactory: () => peer as unknown as RTCPeerConnection
    });

    await transport.start("a-local-peer", "z-remote-peer", false, "");
    await expect(transport.selectedCandidateClass()).resolves.toBe("srflx");

    peer.stats = new Map<string, unknown>();
    await expect(transport.selectedCandidateClass()).resolves.toBeNull();
  });

  it("classifies a peer fallback as declined and an unconnected transport failure as a timeout", async () => {
    const declinedPeer = new FakePeerConnection();
    const declined = new DirectAudioTransport({
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: vi.fn(),
      peerConnectionFactory: () => declinedPeer as unknown as RTCPeerConnection
    });

    await declined.start("a-local-peer", "z-remote-peer", false, "");
    await declined.handleSignal({ kind: "fallback" });
    expect(declined.lastFailureReason()).toBe("declined");

    const failedPeer = new FakePeerConnection();
    const failed = new DirectAudioTransport({
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
      audioHost: document.body,
      onSignal: vi.fn(),
      onState: vi.fn(),
      peerConnectionFactory: () => failedPeer as unknown as RTCPeerConnection
    });

    await failed.start("a-local-peer", "z-remote-peer", false, "");
    failedPeer.connectionState = "failed";
    (failedPeer.onconnectionstatechange as ((event: Event) => void) | null)?.(
      new Event("connectionstatechange")
    );
    expect(failed.lastFailureReason()).toBe("ice_timeout");
  });
});
