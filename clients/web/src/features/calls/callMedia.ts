import {
  ScreenSharePresets,
  Track,
  supportsVP9
} from "livekit-client";
import type {
  Participant,
  Room,
  TrackPublishDefaults
} from "livekit-client";
import { errorText } from "../../lib/format";
import type { Call, CallIceServer, CallMediaKind } from "../../types";
import type { CallApi } from "./callContracts";
import type { VideoTrackView } from "./CallPanelViews";

export function participantVideoTracks(participant: Participant): VideoTrackView[] {
  const tracks: VideoTrackView[] = [];
  let index = 0;
  for (const publication of participant.videoTrackPublications?.values() || []) {
    const track = publication.videoTrack;
    if (!track) continue;
    const source = publication.source === Track.Source.ScreenShare ? "screen_share" : "camera";
    tracks.push({
      id: publication.trackSid || track.sid || `${participant.sid}-${source}-${index++}`,
      source,
      track
    });
  }
  return tracks;
}

export function microphoneCaptureOptions(deviceId: string) {
  return { ...(deviceId ? { deviceId } : {}), echoCancellation: true, noiseSuppression: true, autoGainControl: true };
}

export function cameraCaptureOptions(deviceId: string) {
  return { ...(deviceId ? { deviceId } : {}), resolution: { width: 1280, height: 720, frameRate: 30 }, facingMode: "user" as const };
}

/**
 * VP9 carries the same perceived quality as the VP8 default at a materially
 * lower bitrate, and its SVC layers replace simulcast so the publisher encodes
 * one stream instead of three. `backupCodec` keeps a VP8 track available for
 * subscribers that cannot decode VP9, so selecting it never excludes a
 * participant; publishers that cannot encode it stay on VP8.
 *
 * Screen content is dominated by resolution rather than motion, so it is
 * published at 1080p15 instead of the 1080p30 default — half the bitrate for
 * text that does not move.
 */
/**
 * Supplies the relay the server issued for this participant. Without one, a
 * participant behind a symmetric NAT or a UDP-blocking firewall cannot
 * establish media at all, so the call fails rather than degrades.
 *
 * Returning no `rtcConfig` at all when the server sends no relay leaves the
 * SDK on its own defaults, which is the portable single-host behaviour.
 */
export function callRtcConfig(
  iceServers?: CallIceServer[],
  iceTransportPolicy?: RTCIceTransportPolicy
): { rtcConfig?: RTCConfiguration } {
  const usable = (iceServers || []).filter((server) => server.urls?.length > 0);
  if (usable.length === 0 && !iceTransportPolicy) return {};

  return {
    rtcConfig: {
      ...(usable.length > 0
        ? {
            iceServers: usable.map((server) => ({
              urls: server.urls,
              ...(server.username ? { username: server.username } : {}),
              ...(server.credential ? { credential: server.credential } : {})
            }))
          }
        : {}),
      ...(iceTransportPolicy ? { iceTransportPolicy } : {})
    }
  };
}

export function callPublishDefaults(): TrackPublishDefaults {
  return {
    videoCodec: supportsVP9() ? "vp9" : "vp8",
    backupCodec: true,
    // Both default to enabled for mono tracks. Set explicitly so the bandwidth
    // and packet-loss behaviour of a call does not move with an SDK default.
    dtx: true,
    red: true,
    screenShareEncoding: ScreenSharePresets.h1080fps15.encoding
  };
}

export function cameraConstraints(deviceId: string): MediaTrackConstraints {
  return { ...(deviceId ? { deviceId: { exact: deviceId } } : {}), width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30, max: 30 } };
}

export function formatCallDuration(seconds: number): string {
  const safe = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  const hours = Math.floor(safe / 3_600);
  const minutes = Math.floor((safe % 3_600) / 60);
  const remainder = safe % 60;
  if (hours > 0) return `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`;
  return `${minutes}:${String(remainder).padStart(2, "0")}`;
}

export function mediaBoundaryError(kind: "microphone" | "camera"): string | null {
  if (window.isSecureContext === false) return `${kind === "camera" ? "Camera" : "Microphone"} access requires a secure HTTPS connection.`;
  if (!navigator.mediaDevices?.getUserMedia) return `This browser does not provide ${kind} access.`;
  return null;
}

export function mediaErrorText(reason: unknown, kind: "microphone" | "camera" | "screen" | "device"): string {
  const label = kind === "screen" ? "screen sharing" : kind === "device" ? "media device" : kind;
  if (reason instanceof DOMException) {
    if (reason.name === "NotAllowedError" || reason.name === "SecurityError") return `${capitalize(label)} permission was blocked. Allow access in browser and operating-system settings, then try again.`;
    if (reason.name === "NotFoundError" || reason.name === "OverconstrainedError") return `No available ${label} matches the selected device. Choose another device and try again.`;
    if (reason.name === "NotReadableError" || reason.name === "AbortError") return `The ${label} could not be opened. Close other applications using it, then try again.`;
  }
  return errorText(reason);
}

export function callMediaKind(call: Pick<Call, "media_kind">): CallMediaKind {
  return call?.media_kind === "video" ? "video" : "audio";
}

export function mediaEnabled(kind: CallMediaKind, audioEnabled: boolean, videoEnabled: boolean) {
  return kind === "video" ? videoEnabled : audioEnabled;
}

export function mediaLabel(kind: CallMediaKind) {
  return kind === "video" ? "Video" : "Audio";
}

export function deviceSelection(current: string, devices: MediaDeviceInfo[]) {
  return devices.some(({ deviceId }) => deviceId === current) ? current : devices[0]?.deviceId || "";
}

function capitalize(value: string) {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

export function clearRemoteAudio(container: HTMLDivElement | null) {
  container?.querySelectorAll("[data-k-comms-call-audio]").forEach((element) => element.remove());
}

export function stopRoomLocalTracks(room: Room) {
  for (const publication of room.localParticipant.trackPublications?.values() || []) {
    publication.track?.stop();
  }
}

type CompatibilityApi = CallApi;

export function getCall(api: CompatibilityApi, conversationId: string) {
  if (typeof api.call === "function") return api.call(conversationId);
  if (typeof api.audioCall === "function") return api.audioCall(conversationId);
  throw new Error("Call status is not supported by this client.");
}

export function startNewCall(api: CompatibilityApi, conversationId: string, mediaKind: CallMediaKind) {
  if (typeof api.startCall === "function") return api.startCall(conversationId, mediaKind);
  if (mediaKind === "audio" && typeof api.startAudioCall === "function") return api.startAudioCall(conversationId);
  throw new Error(`${mediaLabel(mediaKind)} calls are not supported by this client.`);
}

export function joinExistingCall(api: CompatibilityApi, conversationId: string, callId: string) {
  if (typeof api.joinCall === "function") return api.joinCall(conversationId, callId);
  if (typeof api.joinAudioCall === "function") return api.joinAudioCall(conversationId, callId);
  throw new Error("Joining calls is not supported by this client.");
}

export function endExistingCall(api: CompatibilityApi, conversationId: string, callId: string) {
  if (typeof api.endCall === "function") return api.endCall(conversationId, callId);
  if (typeof api.endAudioCall === "function") return api.endAudioCall(conversationId, callId);
  throw new Error("Ending calls is not supported by this client.");
}
