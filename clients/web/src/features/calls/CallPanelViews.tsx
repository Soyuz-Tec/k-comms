import { useEffect, useRef } from "react";
import type { LocalVideoTrack, RemoteVideoTrack } from "livekit-client";
import { AppIcon } from "../../components/AppIcon";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import {
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
import type { Call, CallMediaKind } from "../../types";
import type { CallPhase } from "./callContracts";
import { mediaEnabled, mediaLabel } from "./callMedia";

type VideoTrack = LocalVideoTrack | RemoteVideoTrack;

export interface VideoTrackView {
  id: string;
  source: "camera" | "screen_share";
  track: VideoTrack;
}

export interface ParticipantView {
  id: string;
  name: string;
  local: boolean;
  microphoneEnabled: boolean;
  cameraEnabled: boolean;
  screenShareEnabled: boolean;
  speaking: boolean;
  videoTracks: VideoTrackView[];
}

export function CallActions({
  phase,
  call,
  activeKind,
  requestedKind,
  joined,
  accessRevoked,
  audioEnabled,
  videoEnabled,
  showVideoAction,
  onOpen
}: {
  phase: CallPhase;
  call: Call | null;
  activeKind: CallMediaKind | null;
  requestedKind: CallMediaKind;
  joined: boolean;
  accessRevoked: boolean;
  audioEnabled: boolean;
  videoEnabled: boolean;
  showVideoAction: boolean;
  onOpen: (kind: CallMediaKind) => void;
}) {
  if (activeKind || joined || phase === "error" || accessRevoked) {
    const kind = activeKind || requestedKind;
    const enabled = mediaEnabled(kind, audioEnabled, videoEnabled);
    const label = accessRevoked
      ? `${mediaLabel(kind)} access revoked`
      : phase === "error"
        ? `Retry ${kind} call`
        : joined
          ? `In ${kind} call`
          : call?.status === "active"
            ? `Join ${kind} call`
            : `Start ${kind} call`;
    return <CallAction kind={kind} label={label} active={Boolean(call?.status === "active" || joined)} disabled={!enabled || accessRevoked || phase === "joining" || phase === "leaving" || joined} onOpen={onOpen} />;
  }

  return <>
    <CallAction
      kind="audio"
      label={phase === "loading" ? "Checking audio call…" : audioEnabled ? "Start audio call" : "Audio calls disabled"}
      active={false}
      disabled={!audioEnabled || phase === "loading" || phase === "joining" || phase === "leaving"}
      onOpen={onOpen}
    />
    {showVideoAction && <CallAction
      kind="video"
      label={phase === "loading" ? "Checking video call…" : videoEnabled ? "Start video call" : "Video calls disabled"}
      active={false}
      disabled={!videoEnabled || phase === "loading" || phase === "joining" || phase === "leaving"}
      onOpen={onOpen}
    />}
  </>;
}

function CallAction({ kind, label, active, disabled, onOpen }: { kind: CallMediaKind; label: string; active: boolean; disabled: boolean; onOpen: (kind: CallMediaKind) => void }) {
  return <button className={`button compact call-launch-button ${active ? "audio-call-active" : "ghost"}`} type="button" disabled={disabled} aria-haspopup="dialog" onClick={() => onOpen(kind)}><AppIcon name={kind === "video" ? "video" : "phone"} />{label}</button>;
}

export function CallPrejoinDialog({
  kind,
  conversationTitle,
  joining,
  existingCall,
  microphones,
  cameras,
  selectedMicrophone,
  selectedCamera,
  microphoneEnabled,
  cameraEnabled,
  previewBusy,
  previewVideoRef,
  error,
  onMicrophone,
  onCamera,
  onMicrophoneEnabled,
  onCameraEnabled,
  onCancel,
  onJoin
}: {
  kind: CallMediaKind;
  conversationTitle: string;
  joining: boolean;
  existingCall: boolean;
  microphones: MediaDeviceInfo[];
  cameras: MediaDeviceInfo[];
  selectedMicrophone: string;
  selectedCamera: string;
  microphoneEnabled: boolean;
  cameraEnabled: boolean;
  previewBusy: boolean;
  previewVideoRef: React.RefObject<HTMLVideoElement | null>;
  error: string | null;
  onMicrophone: (deviceId: string) => void;
  onCamera: (deviceId: string) => void;
  onMicrophoneEnabled: (enabled: boolean) => void;
  onCameraEnabled: (enabled: boolean) => void;
  onCancel: () => void;
  onJoin: (publishMicrophone: boolean, publishCamera: boolean) => void;
}) {
  const dialogRef = useModalDialog(onCancel);
  const title = existingCall
    ? `Join the ${kind} call`
    : `Start ${kind === "audio" ? "an" : "a"} ${kind} call`;
  return <div className="modal-backdrop">
    <section ref={dialogRef} className="modal-dialog audio-prejoin-dialog call-prejoin-dialog" role="dialog" aria-modal="true" aria-label={title} tabIndex={-1}>
      <header className="prejoin-heading">
        <div>
          <h2 id="call-prejoin-title">Ready to join?</h2>
          <p>{conversationTitle}</p>
        </div>
        <AppSurfaceControlButton
          accessibleLabel="Close call setup"
          data-initial-focus
          kind="close"
          onClick={onCancel}
        />
      </header>
      <p className="prejoin-intro">{kind === "video" ? "Choose exactly which devices to publish before entering. Camera preview stays on this device until you join." : "Choose whether to publish your microphone. Camera and screen sharing stay off."}</p>
      {error && <div className="form-error" role="alert">{error}</div>}
      {kind === "video" && <div className={`camera-preview ${cameraEnabled ? "enabled" : ""}`}>
        {cameraEnabled ? <video ref={previewVideoRef} data-k-comms-camera-preview autoPlay muted playsInline aria-label="Camera preview" /> : <div className="camera-preview-placeholder" aria-hidden="true">Camera off</div>}
        {previewBusy && <span className="camera-preview-status" role="status">Starting camera preview…</span>}
      </div>}
      <div className="prejoin-mode-cards" aria-label="Call mode">
        <div className={kind === "audio" ? "selected" : ""}>
          <span aria-hidden="true"><AppIcon name="phone" /></span>
          <strong>Audio</strong>
          <small>Voice only</small>
        </div>
        <div className={kind === "video" ? "selected" : ""}>
          <span aria-hidden="true"><AppIcon name="video" /></span>
          <strong>Video</strong>
          <small>With camera</small>
        </div>
      </div>
      <div className="call-capture-indicator prejoin" role="status" aria-label="Prejoin capture status">
        <strong>Before joining</strong>
        <span>Microphone is not capturing</span>
        {kind === "video" && (
          <span className={cameraEnabled ? "active" : undefined}>
            Camera preview {cameraEnabled ? "on locally" : "off"}
          </span>
        )}
      </div>
      <div className="prejoin-consent-grid">
        <label className="checkbox-field"><input type="checkbox" checked={microphoneEnabled} disabled={joining} onChange={(event) => onMicrophoneEnabled(event.target.checked)} />Use microphone when I join</label>
        {kind === "video" && <label className="checkbox-field"><input type="checkbox" checked={cameraEnabled} disabled={joining || previewBusy} onChange={(event) => onCameraEnabled(event.target.checked)} />Use camera when I join</label>}
      </div>
      <details className="prejoin-device-settings">
        <summary>Device settings</summary>
        <div className="call-device-grid prejoin-device-grid">
          <label className="field">Microphone
            <select value={selectedMicrophone} disabled={joining || microphones.length === 0} onChange={(event) => onMicrophone(event.target.value)}>
              {microphones.length === 0 && <option value="">Browser default</option>}
              {microphones.map((device, index) => <option key={device.deviceId || `prejoin-microphone-${index}`} value={device.deviceId}>{device.label || `Microphone ${index + 1}`}</option>)}
            </select>
            <small>Permission is requested only if you choose to use your microphone.</small>
          </label>
          {kind === "video" && <label className="field">Camera
            <select value={selectedCamera} disabled={joining || previewBusy || cameras.length === 0} onChange={(event) => onCamera(event.target.value)}>
              {cameras.length === 0 && <option value="">Browser default</option>}
              {cameras.map((device, index) => <option key={device.deviceId || `prejoin-camera-${index}`} value={device.deviceId}>{device.label || `Camera ${index + 1}`}</option>)}
            </select>
            <small>Camera permission is requested when you turn the preview on.</small>
          </label>}
        </div>
      </details>
      <div className="form-actions audio-prejoin-actions">
        <button className="button ghost prejoin-cancel-action" type="button" onClick={onCancel}>Cancel</button>
        {kind === "audio" ? <>
          <button className="button ghost" type="button" disabled={joining} onClick={() => onJoin(false, false)}>{joining ? "Joining…" : "Join muted"}</button>
          <button className="button primary" type="button" disabled={joining} onClick={() => onJoin(true, false)}>{joining ? "Joining…" : "Join with microphone"}</button>
        </> : <button className="button primary" type="button" disabled={joining || previewBusy} onClick={() => onJoin(microphoneEnabled, cameraEnabled)}>{joining ? "Joining…" : "Join video call"}</button>}
      </div>
    </section>
  </div>;
}

export function AudioParticipantStage({ participants }: { participants: ParticipantView[] }) {
  const duplicateNames = duplicateParticipantNames(
    participants.map((participant) => ({
      id: participant.id,
      display_name: participant.name
    }))
  );
  return <section className="audio-participant-stage" aria-label="Audio call participants">
    <div
      className={`audio-participant-grid participant-count-${Math.min(participants.length, 4)}`}
      role="list"
      aria-label="Call participants"
    >
      {participants.map((participant) => {
        const identifier = participantIdentifier(
          { id: participant.id, display_name: participant.name },
          duplicateNames
        );
        const microphoneStatus = participant.microphoneEnabled ? "Microphone on" : "Muted";
        return <article
          className={`audio-participant-card ${participant.speaking ? "speaking" : ""} ${participant.local ? "local" : ""}`}
          role="listitem"
          aria-label={`${identifier}${participant.local ? " (you)" : ""}, ${microphoneStatus}${participant.speaking ? ", Speaking" : ""}`}
          key={participant.id}
          data-participant-id={participant.id}
        >
          <span className="audio-participant-avatar" aria-hidden="true">
            {initials(participant.name)}
          </span>
          <strong>{identifier}{participant.local ? " (you)" : ""}</strong>
          <span className="audio-participant-media">
            <AppIcon name={participant.microphoneEnabled ? "mic" : "micOff"} />
            <span>{microphoneStatus}</span>
          </span>
        </article>;
      })}
    </div>
    {participants.length === 1 && (
      <p className="audio-participant-solo">Only you are in the call.</p>
    )}
  </section>;
}

export function prioritizeVideoParticipants(participants: ParticipantView[]): ParticipantView[] {
  return participants
    .map((participant, index) => ({ participant, index }))
    .sort((left, right) => {
      const priorityDifference = videoParticipantPriority(left.participant)
        - videoParticipantPriority(right.participant);
      return priorityDifference || left.index - right.index;
    })
    .map(({ participant }) => participant);
}

function videoParticipantPriority(participant: ParticipantView): number {
  const sharingScreen = participant.screenShareEnabled
    || participant.videoTracks.some((track) => track.source === "screen_share");
  if (sharingScreen) return 0;
  if (!participant.local && participant.speaking) return 1;
  if (!participant.local) return 2;
  return 3;
}

export function VideoParticipantGrid({ participants }: { participants: ParticipantView[] }) {
  const duplicateNames = duplicateParticipantNames(
    participants.map((participant) => ({
      id: participant.id,
      display_name: participant.name
    }))
  );
  return <div className={`video-participant-grid participant-count-${Math.min(participants.length, 4)}`} role="list" aria-label="Video participants">
    {participants.map((participant) => {
      const identifier = participantIdentifier(
        { id: participant.id, display_name: participant.name },
        duplicateNames
      );
      const microphoneStatus = participant.microphoneEnabled ? "Microphone on" : "Muted";
      const cameraStatus = participant.cameraEnabled ? "Camera on" : "Camera off";
      return <article className={`video-participant-tile ${participant.speaking ? "speaking" : ""} ${participant.local ? "local" : ""}`} role="listitem" aria-label={`${identifier}${participant.local ? " (you)" : ""}, ${microphoneStatus}, ${cameraStatus}${participant.speaking ? ", Speaking" : ""}`} key={participant.id} data-participant-id={participant.id}>
      <div className="video-track-stack">
        {participant.videoTracks.length > 0
          ? participant.videoTracks.map((video) => <VideoTrackElement key={video.id} video={video} participant={participant} participantIdentifier={identifier} />)
          : <div className="video-placeholder" aria-hidden="true"><span>{initials(participant.name)}</span><small>{participant.cameraEnabled ? "Starting video…" : "Camera off"}</small></div>}
      </div>
      <div className="video-participant-caption">
        <strong>{identifier}{participant.local ? " (you)" : ""}</strong>
        {/*
          * Decorative state trail. The tile's aria-label already states mic,
          * camera and speaking, so none of this is announced twice. The level
          * bars only appear when someone is actually audible — speaking while
          * muted would be a contradiction, not a state worth drawing.
          */}
        {(!participant.microphoneEnabled || !participant.cameraEnabled || participant.speaking) && (
          <span className="video-participant-exceptions" aria-hidden="true">
            {!participant.microphoneEnabled && <AppIcon name="micOff" />}
            {!participant.cameraEnabled && <AppIcon name="videoOff" />}
            {participant.speaking && participant.microphoneEnabled && (
              <span className="video-speaking-bars"><i /><i /><i /></span>
            )}
          </span>
        )}
      </div>
    </article>;
    })}
  </div>;
}

function VideoTrackElement({ video, participant, participantIdentifier: identifier }: { video: VideoTrackView; participant: ParticipantView; participantIdentifier: string }) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const element = video.track.attach();
    if (!(element instanceof HTMLVideoElement)) return;
    element.autoplay = true;
    element.playsInline = true;
    element.muted = participant.local;
    element.setAttribute("data-k-comms-call-video", participant.local ? "local" : "remote");
    element.setAttribute("data-participant-id", participant.id);
    element.setAttribute("data-source", video.source);
    container.replaceChildren(element);
    return () => {
      video.track.detach(element);
      element.srcObject = null;
      element.remove();
    };
  }, [participant.id, participant.local, video.source, video.track]);
  return <div className={`video-track-frame ${video.source === "screen_share" ? "screen-share" : "camera"}`}>
    <div ref={containerRef} className="video-track-mount" aria-hidden="true" />
    <span className="visually-hidden">{identifier} {video.source === "screen_share" ? "screen share" : "camera"}</span>
  </div>;
}



function initials(name: string) {
  return name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]?.toUpperCase() || "").join("") || "?";
}
