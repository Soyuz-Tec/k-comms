import { useCallback, useRef, useState } from "react";
import type { MutableRefObject } from "react";
import type { Participant, Room } from "livekit-client";
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
