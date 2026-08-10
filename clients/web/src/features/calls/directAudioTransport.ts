export type DirectAudioSignal =
  | { kind: "offer" | "answer"; sdp: string }
  | { kind: "ice"; candidate: string; sdp_mid: string | null; sdp_mline_index: number | null }
  | { kind: "media"; enabled: boolean }
  | { kind: "fallback" };

export type DirectAudioTransportState = "idle" | "connecting" | "connected" | "failed";

const MAX_PENDING_ICE_CANDIDATES = 64;

interface DirectAudioTransportOptions {
  iceServers: RTCIceServer[];
  audioHost: HTMLElement;
  onSignal: (signal: DirectAudioSignal) => void;
  onState: (state: DirectAudioTransportState) => void;
  onPlaybackBlocked?: () => void;
  peerConnectionFactory?: (configuration: RTCConfiguration) => RTCPeerConnection;
  getUserMedia?: (constraints: MediaStreamConstraints) => Promise<MediaStream>;
  createAudioElement?: () => HTMLAudioElement;
}

export class DirectAudioTransport {
  private peerConnection: RTCPeerConnection | null = null;
  private localTrack: MediaStreamTrack | null = null;
  private remoteAudio: HTMLAudioElement | null = null;
  private pendingCandidates: RTCIceCandidateInit[] = [];
  private microphoneDeviceId = "";
  private stopped = false;
  private connectionTimeout: ReturnType<typeof setTimeout> | null = null;
  private lifecycleGeneration = 0;
  private microphoneReplacementGeneration = 0;

  constructor(private readonly options: DirectAudioTransportOptions) {}

  async start(
    localPeerId: string,
    remotePeerId: string,
    microphoneEnabled: boolean,
    microphoneDeviceId: string
  ): Promise<void> {
    this.stop();
    this.stopped = false;
    this.lifecycleGeneration += 1;
    this.microphoneDeviceId = microphoneDeviceId;
    this.options.onState("connecting");

    const peerConnection = (this.options.peerConnectionFactory || ((configuration) => (
      new RTCPeerConnection(configuration)
    )))({ iceServers: this.options.iceServers });
    this.peerConnection = peerConnection;
    this.connectionTimeout = setTimeout(() => this.fail(), 12_000);
    peerConnection.addTransceiver("audio", { direction: "sendrecv" });
    peerConnection.onicecandidate = (event) => {
      if (!event.candidate || this.stopped) return;
      this.options.onSignal({
        kind: "ice",
        candidate: event.candidate.candidate,
        sdp_mid: event.candidate.sdpMid,
        sdp_mline_index: event.candidate.sdpMLineIndex
      });
    };
    peerConnection.ontrack = (event) => {
      if (event.track.kind !== "audio") {
        event.track.stop();
        this.fail();
        return;
      }
      this.attachRemoteAudio(new MediaStream([event.track]));
    };
    peerConnection.ondatachannel = (event) => {
      event.channel.close();
      this.fail();
    };
    peerConnection.onconnectionstatechange = () => {
      if (this.stopped || this.peerConnection !== peerConnection) return;
      if (peerConnection.connectionState === "connected") {
        this.clearConnectionTimeout();
        this.options.onState("connected");
      }
      if (["failed", "closed"].includes(peerConnection.connectionState)) this.fail();
      if (peerConnection.connectionState === "disconnected") this.fail();
    };

    if (microphoneEnabled) await this.setMicrophoneEnabled(true);

    if (localPeerId < remotePeerId) {
      const offer = await peerConnection.createOffer();
      if (this.stopped || this.peerConnection !== peerConnection) return;
      await peerConnection.setLocalDescription(offer);
      if (offer.sdp) this.options.onSignal({ kind: "offer", sdp: offer.sdp });
    }
  }

  async handleSignal(signal: DirectAudioSignal): Promise<void> {
    const peerConnection = this.peerConnection;
    if (!peerConnection || this.stopped) return;

    if (signal.kind === "fallback") {
      this.fail();
      return;
    }
    if (signal.kind === "media") return;
    if (signal.kind === "ice") {
      const candidate: RTCIceCandidateInit = {
        candidate: signal.candidate,
        sdpMid: signal.sdp_mid,
        sdpMLineIndex: signal.sdp_mline_index
      };
      if (!peerConnection.remoteDescription) {
        if (this.pendingCandidates.length >= MAX_PENDING_ICE_CANDIDATES) {
          this.fail();
          throw new Error("The direct audio ICE candidate limit was exceeded.");
        }
        this.pendingCandidates.push(candidate);
      } else {
        await peerConnection.addIceCandidate(candidate);
      }
      return;
    }

    if (!audioOnlySdp(signal.sdp)) {
      this.fail();
      throw new Error("The direct audio session description is not audio-only.");
    }
    await peerConnection.setRemoteDescription({ type: signal.kind, sdp: signal.sdp });
    await this.flushCandidates(peerConnection);
    if (signal.kind === "offer") {
      const answer = await peerConnection.createAnswer();
      if (this.stopped || this.peerConnection !== peerConnection) return;
      await peerConnection.setLocalDescription(answer);
      if (answer.sdp) this.options.onSignal({ kind: "answer", sdp: answer.sdp });
    }
  }

  async setMicrophoneEnabled(enabled: boolean): Promise<void> {
    if (!enabled) {
      if (this.localTrack) this.localTrack.enabled = false;
      return;
    }

    if (!this.localTrack) await this.replaceMicrophone(this.microphoneDeviceId);
    if (this.localTrack) this.localTrack.enabled = true;
  }

  async switchMicrophone(deviceId: string): Promise<void> {
    this.microphoneDeviceId = deviceId;
    if (this.localTrack) await this.replaceMicrophone(deviceId);
  }

  async selectSpeaker(deviceId: string): Promise<void> {
    const audio = this.remoteAudio as (HTMLAudioElement & { setSinkId?: (id: string) => Promise<void> }) | null;
    if (audio?.setSinkId) await audio.setSinkId(deviceId);
  }

  async enablePlayback(): Promise<void> {
    if (this.remoteAudio) await this.remoteAudio.play();
  }

  stop(): void {
    this.stopped = true;
    this.lifecycleGeneration += 1;
    this.microphoneReplacementGeneration += 1;
    this.clearConnectionTimeout();
    this.peerConnection?.close();
    this.peerConnection = null;
    this.localTrack?.stop();
    this.localTrack = null;
    this.pendingCandidates = [];
    if (this.remoteAudio) {
      this.remoteAudio.pause();
      this.remoteAudio.srcObject = null;
      this.remoteAudio.remove();
      this.remoteAudio = null;
    }
    this.options.onState("idle");
  }

  private async replaceMicrophone(deviceId: string): Promise<void> {
    const lifecycleGeneration = this.lifecycleGeneration;
    const replacementGeneration = ++this.microphoneReplacementGeneration;
    const peerConnection = this.peerConnection;
    const getUserMedia = this.options.getUserMedia || ((constraints) => (
      navigator.mediaDevices.getUserMedia(constraints)
    ));
    let stream: MediaStream | null = null;
    let committedTrack: MediaStreamTrack | null = null;

    try {
      stream = await getUserMedia({
        audio: deviceId ? { deviceId: { exact: deviceId } } : true,
        video: false
      });
      const nextTrack = stream.getAudioTracks()[0];
      if (!nextTrack) throw new Error("No microphone audio track was returned.");
      if (
        this.stopped ||
        this.lifecycleGeneration !== lifecycleGeneration ||
        this.microphoneReplacementGeneration !== replacementGeneration ||
        this.peerConnection !== peerConnection
      ) return;

      const sender = peerConnection?.getSenders().find((candidate) => (
        candidate.track?.kind === "audio" || candidate.track === null
      ));
      if (!sender) throw new Error("The direct audio sender is unavailable.");
      await sender.replaceTrack(nextTrack);
      if (
        this.stopped ||
        this.lifecycleGeneration !== lifecycleGeneration ||
        this.microphoneReplacementGeneration !== replacementGeneration ||
        this.peerConnection !== peerConnection
      ) return;

      const previousTrack = this.localTrack;
      this.localTrack = nextTrack;
      committedTrack = nextTrack;
      previousTrack?.stop();
    } finally {
      if (stream) {
        for (const track of new Set(stream.getTracks())) {
          if (track !== committedTrack) track.stop();
        }
      }
    }
  }

  private attachRemoteAudio(stream?: MediaStream): void {
    if (!stream || this.stopped) return;
    if (this.remoteAudio) this.remoteAudio.remove();
    const audio = (this.options.createAudioElement || (() => document.createElement("audio")))();
    audio.autoplay = true;
    audio.setAttribute("playsinline", "");
    audio.dataset.kCommsDirectAudio = "true";
    audio.srcObject = stream;
    this.options.audioHost.appendChild(audio);
    this.remoteAudio = audio;
    void audio.play().catch(() => this.options.onPlaybackBlocked?.());
  }

  private async flushCandidates(peerConnection: RTCPeerConnection): Promise<void> {
    const candidates = this.pendingCandidates.splice(0);
    for (const candidate of candidates) await peerConnection.addIceCandidate(candidate);
  }

  private fail(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.lifecycleGeneration += 1;
    this.microphoneReplacementGeneration += 1;
    this.clearConnectionTimeout();
    this.peerConnection?.close();
    this.peerConnection = null;
    this.localTrack?.stop();
    this.localTrack = null;
    this.pendingCandidates = [];
    if (this.remoteAudio) {
      this.remoteAudio.pause();
      this.remoteAudio.srcObject = null;
      this.remoteAudio.remove();
      this.remoteAudio = null;
    }
    this.options.onState("failed");
  }

  private clearConnectionTimeout(): void {
    if (this.connectionTimeout) clearTimeout(this.connectionTimeout);
    this.connectionTimeout = null;
  }
}

function audioOnlySdp(sdp: string): boolean {
  if (!sdp || new TextEncoder().encode(sdp).byteLength > 16_384 || sdp.includes("\0")) return false;
  const lines = sdp.replaceAll("\r\n", "\n").split("\n").filter(Boolean);
  const mediaLines = lines.filter((line) => line.startsWith("m="));
  return (
    lines[0] === "v=0" &&
    mediaLines.length === 1 &&
    /^m=audio \d{1,5} UDP\/TLS\/RTP\/SAVPF(?: \d{1,3})+$/.test(mediaLines[0] || "") &&
    lines.some((line) => /^a=ice-ufrag:\S{4,256}$/.test(line)) &&
    lines.some((line) => /^a=ice-pwd:\S{22,256}$/.test(line)) &&
    lines.some((line) => /^a=fingerprint:sha-256 (?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$/.test(line)) &&
    lines.some((line) => ["a=setup:actpass", "a=setup:active", "a=setup:passive"].includes(line)) &&
    lines.includes("a=rtcp-mux") &&
    !lines.some((line) => line.startsWith("a=sctp-port:") || line.startsWith("a=sctpmap:"))
  );
}
