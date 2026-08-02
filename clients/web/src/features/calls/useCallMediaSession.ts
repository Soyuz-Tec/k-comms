import { useCallback, useRef, useState } from "react";
import type { MutableRefObject } from "react";
import { Track, type Participant, type Room } from "livekit-client";
import type { CallMediaKind } from "../../types";
import type { ParticipantView } from "./CallPanelViews";
import { participantVideoTracks } from "./callMedia";
import { useLiveKitRoom } from "./useLiveKitRoom";
import { useMediaDevices } from "./useMediaDevices";

export function useCallMediaSession({
  currentUserDisplayName,
  mountedRef,
  setError
}: {
  currentUserDisplayName: string;
  mountedRef: MutableRefObject<boolean>;
  setError: (error: string | null) => void;
}) {
  const [microphoneEnabled, setMicrophoneEnabled] = useState(false);
  const [cameraEnabled, setCameraEnabled] = useState(false);
  const [screenShareEnabled, setScreenShareEnabled] = useState(false);
  const [audioBlocked, setAudioBlocked] = useState(false);
  const [videoBlocked, setVideoBlocked] = useState(false);
  const [participants, setParticipants] = useState<ParticipantView[]>([]);
  const roomMediaKindRef = useRef<CallMediaKind | null>(null);
  const pendingMediaKindRef = useRef<CallMediaKind | null>(null);
  const liveKit = useLiveKitRoom();
  const devices = useMediaDevices({ mountedRef, setError });

  const resetMediaState = useCallback(() => {
    setParticipants([]);
    setMicrophoneEnabled(false);
    setCameraEnabled(false);
    setScreenShareEnabled(false);
    setAudioBlocked(false);
    setVideoBlocked(false);
  }, []);

  const updateRoomState = useCallback(
    (room: Room) => {
      if (liveKit.roomRef.current !== room) return;
      const all: Participant[] = [
        room.localParticipant,
        ...room.remoteParticipants.values()
      ];
      setParticipants(
        all.map((participant) => ({
          id: participant.identity || participant.sid,
          userId: participantUserId(participant.metadata),
          providerIdentity: participant.identity,
          microphoneTrackSid: microphoneTrackSid(participant),
          name: participant.isLocal
            ? currentUserDisplayName
            : participant.name ||
              participant.identity ||
              "Call participant",
          local: participant.isLocal,
          microphoneEnabled: participant.isMicrophoneEnabled,
          cameraEnabled: participant.isCameraEnabled,
          screenShareEnabled: participant.isScreenShareEnabled,
          speaking: participant.isSpeaking,
          connectionQuality: normalizedConnectionQuality(participant.connectionQuality),
          videoTracks: participantVideoTracks(participant)
        }))
      );
      setMicrophoneEnabled(room.localParticipant.isMicrophoneEnabled);
      setCameraEnabled(room.localParticipant.isCameraEnabled);
      setScreenShareEnabled(room.localParticipant.isScreenShareEnabled);
    },
    [currentUserDisplayName, liveKit.roomRef]
  );

  return {
    ...devices,
    ...liveKit,
    audioBlocked,
    cameraEnabled,
    microphoneEnabled,
    participants,
    pendingMediaKindRef,
    resetMediaState,
    roomMediaKindRef,
    screenShareEnabled,
    setAudioBlocked,
    setCameraEnabled,
    setMicrophoneEnabled,
    setScreenShareEnabled,
    setVideoBlocked,
    updateRoomState,
    videoBlocked
  };
}

function microphoneTrackSid(participant: Participant): string | null {
  const microphoneSource = Track.Source?.Microphone;
  if (microphoneSource && typeof participant.getTrackPublication === "function") {
    return participant.getTrackPublication(microphoneSource)?.trackSid || null;
  }
  for (const publication of participant.audioTrackPublications?.values() || []) {
    if (!microphoneSource || publication.source === microphoneSource) {
      return publication.trackSid || null;
    }
  }
  return null;
}

function participantUserId(metadata: string | undefined): string | null {
  if (!metadata) return null;
  try {
    const value = JSON.parse(metadata) as { user_id?: unknown };
    return typeof value.user_id === "string" ? value.user_id : null;
  } catch {
    return null;
  }
}

function normalizedConnectionQuality(value: unknown): ParticipantView["connectionQuality"] {
  const quality = String(value || "unknown").toLowerCase();
  if (quality.includes("excellent")) return "excellent";
  if (quality.includes("good")) return "good";
  if (quality.includes("poor")) return "poor";
  if (quality.includes("lost")) return "lost";
  return "unknown";
}
