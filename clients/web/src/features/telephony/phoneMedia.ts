import { Room, RoomEvent, Track } from "livekit-client";
import type { RemoteTrack } from "livekit-client";
import type { CallCredential } from "../../types";

export type PhoneMediaState = "connecting" | "connected" | "reconnecting" | "disconnected";

/** Loaded only after explicit dial/answer, never on incoming ringing. */
export class PhoneMedia {
  private readonly room: Room;
  private stopped = false;
  private readonly audioElements = new Set<HTMLMediaElement>();

  constructor(
    credential: CallCredential,
    private readonly container: HTMLDivElement,
    private readonly onState: (state: PhoneMediaState) => void,
    private readonly onPlaybackBlocked: (blocked: boolean) => void
  ) {
    this.room = new Room({
      audioCaptureDefaults: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      publishDefaults: { dtx: true, red: true },
      ...(credential.ice_servers?.length ? { rtcConfig: { iceServers: credential.ice_servers } } : {})
    });
    this.room.on(RoomEvent.TrackSubscribed, (track: RemoteTrack) => {
      if (this.stopped || track.kind !== Track.Kind.Audio) return;
      const element = track.attach();
      this.audioElements.add(element);
      this.container.append(element);
    });
    this.room.on(RoomEvent.TrackUnsubscribed, (track: RemoteTrack) => {
      for (const element of track.detach()) { this.audioElements.delete(element); element.remove(); }
    });
    this.room.on(RoomEvent.Reconnecting, () => { if (!this.stopped) this.onState("reconnecting"); });
    this.room.on(RoomEvent.Reconnected, () => { if (!this.stopped) this.onState("connected"); });
    this.room.on(RoomEvent.AudioPlaybackStatusChanged, (playing: boolean) => { if (!this.stopped) this.onPlaybackBlocked(!playing); });
    this.room.on(RoomEvent.Disconnected, () => {
      if (this.stopped) return;
      this.disconnect();
      this.onState("disconnected");
    });
  }

  async connect(credential: CallCredential): Promise<void> {
    this.onState("connecting");
    await this.room.connect(credential.server_url, credential.participant_token, { autoSubscribe: true });
    if (this.stopped) { this.room.disconnect(); return; }
    await this.room.localParticipant.setMicrophoneEnabled(true);
    if (this.stopped) { this.disconnect(); return; }
    await this.startPlayback();
    if (!this.stopped) this.onState("connected");
  }

  async setMuted(muted: boolean): Promise<void> {
    if (!this.stopped) await this.room.localParticipant.setMicrophoneEnabled(!muted);
  }

  async startPlayback(): Promise<void> {
    if (this.stopped) return;
    try { await this.room.startAudio(); this.onPlaybackBlocked(!this.room.canPlaybackAudio); }
    catch { this.onPlaybackBlocked(true); }
  }

  disconnect(): void {
    this.stopped = true;
    for (const publication of this.room.localParticipant.trackPublications.values()) publication.track?.stop();
    void this.room.disconnect();
    for (const element of this.audioElements) element.remove();
    this.audioElements.clear();
  }
}
