import { useCallback, useRef } from "react";
import { Track, type RemoteTrack, type Room } from "livekit-client";
import { clearRemoteAudio, stopRoomLocalTracks } from "./callMedia";

export function useLiveKitRoom() {
  const roomRef = useRef<Room | null>(null);
  const remoteAudioRef = useRef<HTMLDivElement | null>(null);
  const attachedRemoteTracksRef = useRef<WeakSet<RemoteTrack>>(new WeakSet());
  const manualDisconnectRoomsRef = useRef<WeakSet<Room>>(new WeakSet());

  const disconnectRoom = useCallback(async (room: Room) => {
    manualDisconnectRoomsRef.current.add(room);
    if (roomRef.current === room) roomRef.current = null;
    stopRoomLocalTracks(room);
    await room.disconnect(true).catch(() => undefined);
  }, []);

  const attachRemoteAudio = useCallback((track: RemoteTrack) => {
    if (track.kind !== Track.Kind.Audio || !remoteAudioRef.current) return;
    if (attachedRemoteTracksRef.current.has(track)) return;
    const element = track.attach();
    element.autoplay = true;
    element.setAttribute("data-k-comms-call-audio", "remote");
    attachedRemoteTracksRef.current.add(track);
    remoteAudioRef.current.append(element);
  }, []);

  const removeRemoteAudio = useCallback((track: RemoteTrack) => {
    track.detach().forEach((element) => element.remove());
    attachedRemoteTracksRef.current.delete(track);
  }, []);

  const clearAllRemoteAudio = useCallback(() => {
    clearRemoteAudio(remoteAudioRef.current);
    attachedRemoteTracksRef.current = new WeakSet();
  }, []);

  return {
    attachRemoteAudio,
    clearAllRemoteAudio,
    disconnectRoom,
    manualDisconnectRoomsRef,
    remoteAudioRef,
    removeRemoteAudio,
    roomRef
  };
}
