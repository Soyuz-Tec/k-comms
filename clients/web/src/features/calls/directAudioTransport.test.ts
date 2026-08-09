import { describe, expect, it, vi } from "vitest";
import {
  DirectAudioTransport,
  type DirectAudioSignal,
  type DirectAudioTransportState
} from "./directAudioTransport";

class FakePeerConnection {
  connectionState: RTCPeerConnectionState = "new";
  remoteDescription: RTCSessionDescription | null = null;
  localDescription: RTCSessionDescription | null = null;
  onicecandidate: RTCPeerConnection["onicecandidate"] = null;
  ontrack: RTCPeerConnection["ontrack"] = null;
  onconnectionstatechange: RTCPeerConnection["onconnectionstatechange"] = null;
  sender = {
    track: null as MediaStreamTrack | null,
    replaceTrack: vi.fn(async (track: MediaStreamTrack | null) => {
      this.sender.track = track;
    })
  };
  addTransceiver = vi.fn();
  createOffer = vi.fn(async () => ({ type: "offer", sdp: "offer-sdp" } as RTCSessionDescriptionInit));
  createAnswer = vi.fn(async () => ({ type: "answer", sdp: "answer-sdp" } as RTCSessionDescriptionInit));
  setLocalDescription = vi.fn(async (description: RTCSessionDescriptionInit) => {
    this.localDescription = description as RTCSessionDescription;
  });
  setRemoteDescription = vi.fn(async (description: RTCSessionDescriptionInit) => {
    this.remoteDescription = description as RTCSessionDescription;
  });
  addIceCandidate = vi.fn(async () => undefined);
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
    expect(signals).toContainEqual({ kind: "offer", sdp: "offer-sdp" });
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

    await transport.handleSignal({ kind: "offer", sdp: "remote-offer" });
    expect(peer.setRemoteDescription).toHaveBeenCalledWith({ type: "offer", sdp: "remote-offer" });
    expect(peer.addIceCandidate).toHaveBeenCalledTimes(1);
    expect(signals).toContainEqual({ kind: "answer", sdp: "answer-sdp" });
    transport.stop();
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
});
