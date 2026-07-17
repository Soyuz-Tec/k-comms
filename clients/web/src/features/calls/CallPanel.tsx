import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  ConnectionState,
  DisconnectReason,
  Room,
  RoomEvent,
  Track
} from "livekit-client";
import type {
  LocalVideoTrack,
  Participant,
  RemoteTrack,
  RemoteVideoTrack
} from "livekit-client";
import type { ApiClient } from "../../api";
import { useModalDialog } from "../../components/useModalDialog";
import { errorText } from "../../lib/format";
import type {
  Call,
  CallMediaKind,
  CallRealtimeEvent,
  CallSessionResponse,
  Conversation
} from "../../types";

type CallPhase =
  | "loading"
  | "idle"
  | "prejoin"
  | "joining"
  | "connected"
  | "reconnecting"
  | "leaving"
  | "ended"
  | "error";

type VideoTrack = LocalVideoTrack | RemoteVideoTrack;

interface VideoTrackView {
  id: string;
  source: "camera" | "screen_share";
  track: VideoTrack;
}

interface ParticipantView {
  id: string;
  name: string;
  local: boolean;
  microphoneEnabled: boolean;
  cameraEnabled: boolean;
  screenShareEnabled: boolean;
  speaking: boolean;
  videoTracks: VideoTrackView[];
}

interface CallPanelProps {
  api: ApiClient;
  conversation: Conversation;
  audioEnabled: boolean;
  videoEnabled: boolean;
  currentUserDisplayName: string;
  realtimeEvent?: CallRealtimeEvent | null;
  /** Keeps the audio-only compatibility wrapper to one visible action. */
  showVideoAction?: boolean;
}

export function CallPanel({
  api,
  conversation,
  audioEnabled,
  videoEnabled,
  currentUserDisplayName,
  realtimeEvent,
  showVideoAction = true
}: CallPanelProps) {
  const available = audioEnabled || videoEnabled;
  const [call, setCall] = useState<Call | null>(null);
  const [phase, setPhase] = useState<CallPhase>(available ? "loading" : "idle");
  const [prejoinKind, setPrejoinKind] = useState<CallMediaKind>("audio");
  const [error, setError] = useState<string | null>(null);
  const [microphones, setMicrophones] = useState<MediaDeviceInfo[]>([]);
  const [cameras, setCameras] = useState<MediaDeviceInfo[]>([]);
  const [selectedMicrophone, setSelectedMicrophone] = useState("");
  const [selectedCamera, setSelectedCamera] = useState("");
  const [prejoinMicrophone, setPrejoinMicrophone] = useState(false);
  const [prejoinCamera, setPrejoinCamera] = useState(false);
  const [previewBusy, setPreviewBusy] = useState(false);
  const [previewStream, setPreviewStream] = useState<MediaStream | null>(null);
  const [microphoneEnabled, setMicrophoneEnabled] = useState(false);
  const [cameraEnabled, setCameraEnabled] = useState(false);
  const [screenShareEnabled, setScreenShareEnabled] = useState(false);
  const [audioBlocked, setAudioBlocked] = useState(false);
  const [videoBlocked, setVideoBlocked] = useState(false);
  const [participants, setParticipants] = useState<ParticipantView[]>([]);
  const [accessRevoked, setAccessRevoked] = useState(false);
  const roomRef = useRef<Room | null>(null);
  const roomMediaKindRef = useRef<CallMediaKind | null>(null);
  const pendingMediaKindRef = useRef<CallMediaKind | null>(null);
  const remoteAudioRef = useRef<HTMLDivElement | null>(null);
  const previewVideoRef = useRef<HTMLVideoElement | null>(null);
  const previewStreamRef = useRef<MediaStream | null>(null);
  const attachedRemoteTracksRef = useRef<WeakSet<RemoteTrack>>(new WeakSet());
  const manualDisconnectRoomsRef = useRef<WeakSet<Room>>(new WeakSet());
  const mountedRef = useRef(true);
  const operationGenerationRef = useRef(0);
  const refreshSequenceRef = useRef(0);
  const previewGenerationRef = useRef(0);
  const accessRevokedRef = useRef(false);
  const latestRealtimeEventRef = useRef<CallRealtimeEvent | null>(null);
  const currentCallId = call?.id;
  const currentMediaKind = call ? callMediaKind(call) : prejoinKind;

  const invalidateOperations = useCallback(() => {
    refreshSequenceRef.current += 1;
    operationGenerationRef.current += 1;
    return operationGenerationRef.current;
  }, []);

  const operationIsCurrent = useCallback((generation: number) => (
    mountedRef.current && operationGenerationRef.current === generation
  ), []);

  const stopPreview = useCallback(() => {
    previewGenerationRef.current += 1;
    const stream = previewStreamRef.current;
    previewStreamRef.current = null;
    stream?.getTracks().forEach((track) => track.stop());
    if (previewVideoRef.current) previewVideoRef.current.srcObject = null;
    if (mountedRef.current) {
      setPreviewStream(null);
      setPreviewBusy(false);
    }
  }, []);

  const refreshCall = useCallback(async (preservePrejoin = false) => {
    if (!available || roomRef.current || accessRevokedRef.current) return;
    const generation = operationGenerationRef.current;
    const refreshSequence = ++refreshSequenceRef.current;
    try {
      const activeCall = await getCall(api, conversation.id);
      if (
        !operationIsCurrent(generation) ||
        refreshSequenceRef.current !== refreshSequence ||
        roomRef.current
      ) return;
      const latestEvent = latestRealtimeEventRef.current;
      if (latestEvent?.conversation_id === conversation.id) {
        if (latestEvent.status === "ended" && (!activeCall || activeCall.id === latestEvent.id)) return;
        if (latestEvent.status === "active" && !activeCall) return;
      }
      setCall(activeCall?.status === "active" ? activeCall : null);
      if (activeCall) setPrejoinKind(callMediaKind(activeCall));
      setError(null);
      setPhase((current) => preservePrejoin && (current === "prejoin" || current === "joining") ? current : "idle");
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation) || refreshSequenceRef.current !== refreshSequence) return;
      setError(`Call status is unavailable. ${errorText(reason)}`);
      setPhase("error");
    }
  }, [api, available, conversation.id, operationIsCurrent]);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      invalidateOperations();
      stopPreview();
      const room = roomRef.current;
      roomRef.current = null;
      roomMediaKindRef.current = null;
      pendingMediaKindRef.current = null;
      if (room) void disconnectRoom(room);
      clearAllRemoteAudio();
    };
  }, [invalidateOperations, stopPreview]);

  useEffect(() => {
    if (previewVideoRef.current) previewVideoRef.current.srcObject = previewStream;
  }, [previewStream]);

  useEffect(() => {
    latestRealtimeEventRef.current = null;
    accessRevokedRef.current = false;
    setAccessRevoked(false);
    invalidateOperations();
    stopPreview();
    const room = roomRef.current;
    roomRef.current = null;
    roomMediaKindRef.current = null;
    pendingMediaKindRef.current = null;
    if (room) void disconnectRoom(room);
    clearAllRemoteAudio();
    resetConnectedState();
    setCall(null);

    if (available) {
      setPhase("loading");
      void refreshCall();
    } else {
      setPhase("idle");
    }

    return () => { invalidateOperations(); };
  }, [available, conversation.id, invalidateOperations, refreshCall, stopPreview]);

  useEffect(() => {
    const kind = roomMediaKindRef.current || pendingMediaKindRef.current ||
      ((phase === "prejoin" || phase === "joining") ? prejoinKind : call ? callMediaKind(call) : null);
    if (!kind || mediaEnabled(kind, audioEnabled, videoEnabled)) return;

    invalidateOperations();
    stopPreview();
    const room = roomRef.current;
    roomRef.current = null;
    roomMediaKindRef.current = null;
    pendingMediaKindRef.current = null;
    if (room) void disconnectRoom(room);
    clearAllRemoteAudio();
    resetConnectedState();
    setError(`${mediaLabel(kind)} calls were disabled by workspace policy.`);
    setPhase("idle");
  }, [audioEnabled, call, invalidateOperations, phase, prejoinKind, stopPreview, videoEnabled]);

  useEffect(() => {
    if (!available || !realtimeEvent || realtimeEvent.conversation_id !== conversation.id) return;
    if (accessRevokedRef.current) return;
    latestRealtimeEventRef.current = realtimeEvent;

    if (realtimeEvent.status === "active") {
      if (roomRef.current || currentCallId === realtimeEvent.id) return;
      const kind = callMediaKind(realtimeEvent);
      setPrejoinKind(kind);
      setCall({ ...realtimeEvent, can_end: false });
      setError(null);
      setPhase((current) => current === "prejoin" || current === "joining" ? current : "idle");
      void refreshCall(true);
      return;
    }

    if (currentCallId && currentCallId !== realtimeEvent.id) return;
    const kind = callMediaKind(realtimeEvent);
    invalidateOperations();
    stopPreview();
    const room = roomRef.current;
    roomRef.current = null;
    roomMediaKindRef.current = null;
    pendingMediaKindRef.current = null;
    if (room) void disconnectRoom(room);
    clearAllRemoteAudio();
    resetConnectedState();
    setCall({ ...realtimeEvent, can_end: false });
    setPrejoinKind(kind);
    setError(`The ${kind} call was ended for everyone.`);
    setPhase("ended");
  }, [available, conversation.id, currentCallId, currentMediaKind, invalidateOperations, realtimeEvent, refreshCall, stopPreview]);

  useEffect(() => {
    if (!available) return;
    const refreshIfIdle = () => {
      if (
        document.visibilityState === "visible" &&
        !accessRevokedRef.current &&
        !roomRef.current &&
        phase !== "prejoin" &&
        phase !== "joining"
      ) void refreshCall();
    };
    const timer = window.setInterval(refreshIfIdle, 15_000);
    window.addEventListener("focus", refreshIfIdle);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refreshIfIdle);
    };
  }, [available, phase, refreshCall]);

  useEffect(() => {
    if (phase !== "connected" && phase !== "reconnecting") return;
    const animationFrame = window.requestAnimationFrame(() => {
      const room = roomRef.current;
      if (!room || !remoteAudioRef.current) return;
      for (const participant of room.remoteParticipants.values()) {
        for (const publication of participant.audioTrackPublications?.values() || []) {
          if (publication.isSubscribed && publication.track) attachRemoteAudio(publication.track);
        }
      }
    });
    return () => window.cancelAnimationFrame(animationFrame);
  }, [phase]);

  async function openPrejoin(requestedKind: CallMediaKind) {
    if (accessRevokedRef.current || roomRef.current) return;
    if (phase === "error") {
      setPhase("loading");
      await refreshCall();
      return;
    }
    const kind = call?.status === "active" ? callMediaKind(call) : requestedKind;
    if (!mediaEnabled(kind, audioEnabled, videoEnabled)) return;
    const generation = operationGenerationRef.current;
    pendingMediaKindRef.current = kind;
    setPrejoinKind(kind);
    setPrejoinMicrophone(false);
    setPrejoinCamera(false);
    stopPreview();
    setError(null);
    setPhase("prejoin");
    try {
      const [audioDevices, videoDevices] = await Promise.all([
        Room.getLocalDevices("audioinput", false).catch(() => []),
        kind === "video" ? Room.getLocalDevices("videoinput", false).catch(() => []) : Promise.resolve([])
      ]);
      if (!operationIsCurrent(generation) || roomRef.current) return;
      setMicrophones(audioDevices);
      setSelectedMicrophone((current) => current || audioDevices[0]?.deviceId || "");
      setCameras(videoDevices);
      setSelectedCamera((current) => current || videoDevices[0]?.deviceId || "");
    } catch {
      // Labels can remain unavailable until the user explicitly enables a device.
    }
  }

  async function startCameraPreview(deviceId: string) {
    const boundaryError = mediaBoundaryError("camera");
    if (boundaryError) {
      setPrejoinCamera(false);
      setError(boundaryError);
      return;
    }
    stopPreview();
    const previewGeneration = previewGenerationRef.current;
    setPreviewBusy(true);
    setError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: cameraConstraints(deviceId)
      });
      if (!mountedRef.current || previewGenerationRef.current !== previewGeneration) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      previewStreamRef.current = stream;
      setPreviewStream(stream);
      setPreviewBusy(false);
      const devices = await Room.getLocalDevices("videoinput", false).catch(() => []);
      if (!mountedRef.current || previewGenerationRef.current !== previewGeneration) return;
      setCameras(devices);
      const activeDeviceId = stream.getVideoTracks()[0]?.getSettings().deviceId || deviceId;
      if (activeDeviceId) setSelectedCamera(activeDeviceId);
    } catch (reason: unknown) {
      if (!mountedRef.current || previewGenerationRef.current !== previewGeneration) return;
      setPrejoinCamera(false);
      setPreviewBusy(false);
      setError(mediaErrorText(reason, "camera"));
    }
  }

  async function togglePrejoinCamera(enabled: boolean) {
    setPrejoinCamera(enabled);
    if (!enabled) {
      stopPreview();
      return;
    }
    await startCameraPreview(selectedCamera);
  }

  async function selectPrejoinCamera(deviceId: string) {
    setSelectedCamera(deviceId);
    if (prejoinCamera) await startCameraPreview(deviceId);
  }

  async function join(options: { publishMicrophone: boolean; publishCamera: boolean }) {
    if (accessRevokedRef.current) return;
    const kind = call?.status === "active" ? callMediaKind(call) : prejoinKind;
    if (!mediaEnabled(kind, audioEnabled, videoEnabled)) return;
    const generation = invalidateOperations();
    pendingMediaKindRef.current = kind;
    stopPreview();
    const previousRoom = roomRef.current;
    roomRef.current = null;
    roomMediaKindRef.current = null;
    if (previousRoom) void disconnectRoom(previousRoom);

    let microphoneDeviceId = selectedMicrophone;
    let cameraDeviceId = selectedCamera;
    if (options.publishMicrophone) {
      const boundaryError = mediaBoundaryError("microphone");
      if (boundaryError) { setError(boundaryError); return; }
      try {
        const devices = await Room.getLocalDevices("audioinput", true);
        if (!operationIsCurrent(generation)) return;
        if (devices.length === 0) throw new Error("No microphone was found.");
        microphoneDeviceId = microphoneDeviceId || devices[0]?.deviceId || "";
        setMicrophones(devices);
        setSelectedMicrophone(microphoneDeviceId);
      } catch (reason: unknown) {
        if (operationIsCurrent(generation)) setError(mediaErrorText(reason, "microphone"));
        return;
      }
    }
    if (kind === "video" && options.publishCamera) {
      const boundaryError = mediaBoundaryError("camera");
      if (boundaryError) { setError(boundaryError); return; }
      try {
        const devices = await Room.getLocalDevices("videoinput", true);
        if (!operationIsCurrent(generation)) return;
        if (devices.length === 0) throw new Error("No camera was found.");
        cameraDeviceId = cameraDeviceId || devices[0]?.deviceId || "";
        setCameras(devices);
        setSelectedCamera(cameraDeviceId);
      } catch (reason: unknown) {
        if (operationIsCurrent(generation)) setError(mediaErrorText(reason, "camera"));
        return;
      }
    }

    if (!operationIsCurrent(generation)) return;
    setPhase("joining");
    setError(null);
    let room: Room | null = null;
    try {
      const response = call?.status === "active" && call.conversation_id === conversation.id
        ? await joinExistingCall(api, conversation.id, call.id)
        : await startNewCall(api, conversation.id, kind);
      if (!operationIsCurrent(generation)) return;
      setCall(response.data);

      room = new Room({
        adaptiveStream: true,
        dynacast: true,
        audioCaptureDefaults: microphoneCaptureOptions(microphoneDeviceId),
        videoCaptureDefaults: cameraCaptureOptions(cameraDeviceId)
      });
      bindRoom(room, kind);
      roomRef.current = room;
      roomMediaKindRef.current = kind;
      await room.connect(response.credential.server_url, response.credential.participant_token, {
        autoSubscribe: true
      });
      if (!operationIsCurrent(generation) || roomRef.current !== room) {
        await disconnectRoom(room);
        return;
      }

      try {
        await room.startAudio();
        if (!operationIsCurrent(generation) || roomRef.current !== room) {
          await disconnectRoom(room);
          return;
        }
        setAudioBlocked(!room.canPlaybackAudio);
      } catch {
        if (!operationIsCurrent(generation) || roomRef.current !== room) {
          await disconnectRoom(room);
          return;
        }
        setAudioBlocked(true);
      }
      if (kind === "video") {
        try {
          await room.startVideo();
          if (!operationIsCurrent(generation) || roomRef.current !== room) {
            await disconnectRoom(room);
            return;
          }
          setVideoBlocked(!room.canPlaybackVideo);
        } catch {
          if (!operationIsCurrent(generation) || roomRef.current !== room) {
            await disconnectRoom(room);
            return;
          }
          setVideoBlocked(true);
        }
      }

      if (options.publishMicrophone) {
        try {
          await room.localParticipant.setMicrophoneEnabled(true, microphoneCaptureOptions(microphoneDeviceId));
        } catch (reason: unknown) {
          if (operationIsCurrent(generation) && roomRef.current === room) {
            setError(`You joined muted. ${mediaErrorText(reason, "microphone")}`);
          }
        }
      }
      if (kind === "video" && options.publishCamera) {
        try {
          await room.localParticipant.setCameraEnabled(true, cameraCaptureOptions(cameraDeviceId));
        } catch (reason: unknown) {
          if (operationIsCurrent(generation) && roomRef.current === room) {
            setError(`You joined with your camera off. ${mediaErrorText(reason, "camera")}`);
          }
        }
      }

      if (!operationIsCurrent(generation) || roomRef.current !== room) {
        await disconnectRoom(room);
        return;
      }
      pendingMediaKindRef.current = null;
      updateRoomState(room);
      setPhase("connected");
    } catch (reason: unknown) {
      if (room) await disconnectRoom(room);
      if (roomRef.current === room) roomRef.current = null;
      roomMediaKindRef.current = null;
      pendingMediaKindRef.current = null;
      if (!operationIsCurrent(generation)) return;
      setError(`Unable to join the ${kind} call. ${errorText(reason)}`);
      setPhase("error");
    }
  }

  function bindRoom(room: Room, kind: CallMediaKind) {
    const update = () => updateRoomState(room);
    room.on(RoomEvent.ParticipantConnected, update);
    room.on(RoomEvent.ParticipantDisconnected, update);
    room.on(RoomEvent.TrackPublished, update);
    room.on(RoomEvent.TrackUnpublished, update);
    room.on(RoomEvent.LocalTrackPublished, update);
    room.on(RoomEvent.LocalTrackUnpublished, update);
    room.on(RoomEvent.TrackMuted, update);
    room.on(RoomEvent.TrackUnmuted, update);
    room.on(RoomEvent.ActiveSpeakersChanged, update);
    room.on(RoomEvent.TrackSubscribed, (track) => {
      if (roomRef.current !== room) return;
      attachRemoteAudio(track);
      update();
    });
    room.on(RoomEvent.TrackUnsubscribed, (track) => {
      if (roomRef.current !== room) return;
      removeRemoteAudio(track);
      update();
    });
    room.on(RoomEvent.Reconnecting, () => {
      if (roomRef.current === room) setPhase("reconnecting");
    });
    room.on(RoomEvent.Reconnected, () => {
      if (roomRef.current !== room) return;
      setError(null);
      setPhase("connected");
      update();
    });
    room.on(RoomEvent.ConnectionStateChanged, (state) => {
      if (
        roomRef.current === room &&
        (state === ConnectionState.Reconnecting || state === ConnectionState.SignalReconnecting)
      ) setPhase("reconnecting");
    });
    room.on(RoomEvent.AudioPlaybackStatusChanged, (playing) => {
      if (roomRef.current === room) setAudioBlocked(!playing);
    });
    room.on(RoomEvent.VideoPlaybackStatusChanged, (playing) => {
      if (roomRef.current === room && kind === "video") setVideoBlocked(!playing);
    });
    room.on(RoomEvent.MediaDevicesChanged, () => {
      if (roomRef.current === room) void reloadDevices(kind);
    });
    room.on(RoomEvent.MediaDevicesError, (reason) => {
      if (roomRef.current === room) setError(mediaErrorText(reason, "device"));
    });
    room.on(RoomEvent.Disconnected, (reason?: DisconnectReason) => {
      const wasCurrentRoom = roomRef.current === room;
      if (wasCurrentRoom) roomRef.current = null;
      if (!wasCurrentRoom) return;
      roomMediaKindRef.current = null;
      pendingMediaKindRef.current = null;
      invalidateOperations();
      clearAllRemoteAudio();
      resetConnectedState();
      if (manualDisconnectRoomsRef.current.has(room)) return;

      if (reason === DisconnectReason.PARTICIPANT_REMOVED) {
        accessRevokedRef.current = true;
        setAccessRevoked(true);
        setCall(null);
        setError(`Your access to this ${kind} call was revoked. Sign in again or contact an administrator.`);
        setPhase("ended");
        void disconnectRoom(room);
        return;
      }
      if (reason === DisconnectReason.ROOM_DELETED) {
        setCall(null);
        setError(`The ${kind} call was ended for everyone.`);
        setPhase("ended");
        void disconnectRoom(room);
        return;
      }
      setError(`The ${kind} call connection ended. You can rejoin if the call is still active.`);
      setPhase("ended");
      void refreshCall();
    });
  }

  async function disconnectRoom(room: Room) {
    manualDisconnectRoomsRef.current.add(room);
    if (roomRef.current === room) roomRef.current = null;
    await room.disconnect(true).catch(() => undefined);
  }

  function resetConnectedState() {
    setParticipants([]);
    setMicrophoneEnabled(false);
    setCameraEnabled(false);
    setScreenShareEnabled(false);
    setAudioBlocked(false);
    setVideoBlocked(false);
  }

  function updateRoomState(room: Room) {
    if (roomRef.current !== room) return;
    const all: Participant[] = [room.localParticipant, ...room.remoteParticipants.values()];
    setParticipants(all.map((participant) => ({
      id: participant.identity || participant.sid,
      name: participant.isLocal
        ? currentUserDisplayName
        : participant.name || participant.identity || "Call participant",
      local: participant.isLocal,
      microphoneEnabled: participant.isMicrophoneEnabled,
      cameraEnabled: participant.isCameraEnabled,
      screenShareEnabled: participant.isScreenShareEnabled,
      speaking: participant.isSpeaking,
      videoTracks: participantVideoTracks(participant)
    })));
    setMicrophoneEnabled(room.localParticipant.isMicrophoneEnabled);
    setCameraEnabled(room.localParticipant.isCameraEnabled);
    setScreenShareEnabled(room.localParticipant.isScreenShareEnabled);
  }

  function attachRemoteAudio(track: RemoteTrack) {
    if (track.kind !== Track.Kind.Audio || !remoteAudioRef.current) return;
    if (attachedRemoteTracksRef.current.has(track)) return;
    const element = track.attach();
    element.autoplay = true;
    element.setAttribute("data-k-comms-call-audio", "remote");
    attachedRemoteTracksRef.current.add(track);
    remoteAudioRef.current.append(element);
  }

  function removeRemoteAudio(track: RemoteTrack) {
    track.detach().forEach((element) => element.remove());
    attachedRemoteTracksRef.current.delete(track);
  }

  function clearAllRemoteAudio() {
    clearRemoteAudio(remoteAudioRef.current);
    attachedRemoteTracksRef.current = new WeakSet();
  }

  async function reloadDevices(kind: CallMediaKind) {
    try {
      const [audioDevices, videoDevices] = await Promise.all([
        Room.getLocalDevices("audioinput", false),
        kind === "video" ? Room.getLocalDevices("videoinput", false) : Promise.resolve([])
      ]);
      setMicrophones(audioDevices);
      setSelectedMicrophone((current) => deviceSelection(current, audioDevices));
      setCameras(videoDevices);
      setSelectedCamera((current) => deviceSelection(current, videoDevices));
    } catch {
      // Retain the last known device list through transient browser changes.
    }
  }

  async function selectMicrophone(deviceId: string) {
    const previousDeviceId = selectedMicrophone;
    setSelectedMicrophone(deviceId);
    const room = roomRef.current;
    if (!room || !microphoneEnabled) return;
    try {
      const switched = await room.switchActiveDevice("audioinput", deviceId, true);
      if (!switched) throw new Error("The selected microphone could not be activated.");
      setError(null);
    } catch (reason: unknown) {
      setSelectedMicrophone(previousDeviceId);
      setError(mediaErrorText(reason, "microphone"));
    }
  }

  async function selectCamera(deviceId: string) {
    const previousDeviceId = selectedCamera;
    setSelectedCamera(deviceId);
    const room = roomRef.current;
    if (!room || !cameraEnabled) return;
    try {
      const switched = await room.switchActiveDevice("videoinput", deviceId, true);
      if (!switched) throw new Error("The selected camera could not be activated.");
      setError(null);
      updateRoomState(room);
    } catch (reason: unknown) {
      setSelectedCamera(previousDeviceId);
      setError(mediaErrorText(reason, "camera"));
    }
  }

  async function toggleMicrophone() {
    const room = roomRef.current;
    if (!room) return;
    setError(null);
    try {
      if (!microphoneEnabled) {
        const boundaryError = mediaBoundaryError("microphone");
        if (boundaryError) throw new Error(boundaryError);
        const devices = await Room.getLocalDevices("audioinput", true);
        setMicrophones(devices);
        const deviceId = selectedMicrophone || devices[0]?.deviceId || "";
        if (!deviceId) throw new Error("No microphone was found.");
        setSelectedMicrophone(deviceId);
        await room.localParticipant.setMicrophoneEnabled(true, microphoneCaptureOptions(deviceId));
      } else {
        await room.localParticipant.setMicrophoneEnabled(false);
      }
      updateRoomState(room);
    } catch (reason: unknown) {
      setError(mediaErrorText(reason, "microphone"));
    }
  }

  async function toggleCamera() {
    const room = roomRef.current;
    if (!room || roomMediaKindRef.current !== "video") return;
    setError(null);
    try {
      if (!cameraEnabled) {
        const boundaryError = mediaBoundaryError("camera");
        if (boundaryError) throw new Error(boundaryError);
        const devices = await Room.getLocalDevices("videoinput", true);
        setCameras(devices);
        const deviceId = selectedCamera || devices[0]?.deviceId || "";
        if (!deviceId) throw new Error("No camera was found.");
        setSelectedCamera(deviceId);
        await room.localParticipant.setCameraEnabled(true, cameraCaptureOptions(deviceId));
      } else {
        await room.localParticipant.setCameraEnabled(false);
      }
      updateRoomState(room);
    } catch (reason: unknown) {
      setError(mediaErrorText(reason, "camera"));
    }
  }

  async function toggleScreenShare() {
    const room = roomRef.current;
    if (!room || roomMediaKindRef.current !== "video") return;
    setError(null);
    try {
      await room.localParticipant.setScreenShareEnabled(!screenShareEnabled, {
        audio: false,
        video: true,
        selfBrowserSurface: "exclude",
        surfaceSwitching: "include"
      });
      updateRoomState(room);
    } catch (reason: unknown) {
      setError(mediaErrorText(reason, "screen"));
    }
  }

  async function enablePlayback() {
    const room = roomRef.current;
    if (!room) return;
    try {
      await room.startAudio();
      if (roomMediaKindRef.current === "video") await room.startVideo();
      setAudioBlocked(!room.canPlaybackAudio);
      setVideoBlocked(roomMediaKindRef.current === "video" && !room.canPlaybackVideo);
      setError(null);
    } catch (reason: unknown) {
      setError(`Media playback is still blocked. ${errorText(reason)}`);
    }
  }

  async function leave() {
    const room = roomRef.current;
    const generation = invalidateOperations();
    setPhase("leaving");
    stopPreview();
    roomRef.current = null;
    roomMediaKindRef.current = null;
    pendingMediaKindRef.current = null;
    if (room) await disconnectRoom(room);
    if (!operationIsCurrent(generation)) return;
    clearAllRemoteAudio();
    resetConnectedState();
    setPrejoinMicrophone(false);
    setPrejoinCamera(false);
    setError(null);
    setPhase("idle");
  }

  async function endForEveryone() {
    if (!call?.can_end) return;
    const endingCall = call;
    const generation = invalidateOperations();
    setPhase("leaving");
    setError(null);
    try {
      await endExistingCall(api, endingCall.conversation_id, endingCall.id);
      if (!operationIsCurrent(generation)) return;
      const room = roomRef.current;
      roomRef.current = null;
      roomMediaKindRef.current = null;
      pendingMediaKindRef.current = null;
      if (room) await disconnectRoom(room);
      if (!operationIsCurrent(generation)) return;
      clearAllRemoteAudio();
      resetConnectedState();
      setCall(null);
      setPhase("ended");
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation)) return;
      setError(`Unable to end the call. ${errorText(reason)}`);
      setPhase(roomRef.current ? "connected" : "error");
    }
  }

  const joined = Boolean(roomRef.current) && ["connected", "reconnecting", "leaving"].includes(phase);
  const joinedKind = roomMediaKindRef.current || currentMediaKind;
  const activeKind = call?.status === "active" ? callMediaKind(call) : null;

  return (
    <div className="call-control audio-call-control">
      <CallActions
        phase={phase}
        call={call}
        activeKind={activeKind}
        requestedKind={prejoinKind}
        joined={joined}
        accessRevoked={accessRevoked}
        audioEnabled={audioEnabled}
        videoEnabled={videoEnabled}
        showVideoAction={showVideoAction}
        onOpen={(kind) => void openPrejoin(kind)}
      />

      {(phase === "prejoin" || phase === "joining") && createPortal(
        <CallPrejoinDialog
          kind={prejoinKind}
          joining={phase === "joining"}
          existingCall={call?.status === "active"}
          microphones={microphones}
          cameras={cameras}
          selectedMicrophone={selectedMicrophone}
          selectedCamera={selectedCamera}
          microphoneEnabled={prejoinMicrophone}
          cameraEnabled={prejoinCamera}
          previewBusy={previewBusy}
          previewVideoRef={previewVideoRef}
          error={error}
          onMicrophone={setSelectedMicrophone}
          onCamera={(deviceId) => void selectPrejoinCamera(deviceId)}
          onMicrophoneEnabled={setPrejoinMicrophone}
          onCameraEnabled={(enabled) => void togglePrejoinCamera(enabled)}
          onCancel={() => void leave()}
          onJoin={(publishMicrophone, publishCamera) => void join({ publishMicrophone, publishCamera })}
        />,
        document.body
      )}

      {joined && createPortal(
        <section className={`call-dock audio-call-dock ${joinedKind === "video" ? "video-call-dock" : ""}`} role="region" aria-labelledby="call-title">
          <div className="audio-call-dock-heading">
            <div>
              <span className="eyebrow">{mediaLabel(joinedKind)} call</span>
              <h2 id="call-title">{conversation.title || "Conversation call"}</h2>
            </div>
            <span className={`status-pill ${phase === "reconnecting" ? "neutral" : "success"}`} aria-live="polite">
              {phase === "reconnecting" ? "Reconnecting" : phase === "leaving" ? "Leaving" : "Connected"}
            </span>
          </div>
          {error && <div className="form-error" role="alert">{error}</div>}
          {(audioBlocked || videoBlocked) && <div className="inline-notice" role="status"><span>Browser media playback is paused.</span><button className="button ghost compact" type="button" onClick={() => void enablePlayback()}>{joinedKind === "audio" ? "Enable call audio" : "Enable call media"}</button></div>}
          {joinedKind === "video" && <VideoParticipantGrid participants={participants} />}
          <ul className="audio-participant-list" aria-label="Call participants">
            {participants.map((participant) => <li key={participant.id} className={participant.speaking ? "speaking" : undefined}><span className="audio-participant-mark" aria-hidden="true">{participant.speaking ? "◉" : "○"}</span><span><strong>{participant.name}{participant.local ? " (you)" : ""}</strong><small>{participant.microphoneEnabled ? "Microphone on" : "Muted"}{joinedKind === "video" ? ` · ${participant.cameraEnabled ? "Camera on" : "Camera off"}${participant.screenShareEnabled ? " · Sharing screen" : ""}` : ""}</small></span></li>)}
          </ul>
          <div className="call-device-grid">
            <div className="audio-device-row">
              <label htmlFor="active-audio-input">Microphone</label>
              <select id="active-audio-input" value={selectedMicrophone} disabled={phase !== "connected" || microphones.length === 0} onChange={(event) => void selectMicrophone(event.target.value)}>
                {microphones.length === 0 && <option value="">Default microphone</option>}
                {microphones.map((device, index) => <option key={device.deviceId || `microphone-${index}`} value={device.deviceId}>{device.label || `Microphone ${index + 1}`}</option>)}
              </select>
            </div>
            {joinedKind === "video" && <div className="audio-device-row">
              <label htmlFor="active-video-input">Camera</label>
              <select id="active-video-input" value={selectedCamera} disabled={phase !== "connected" || cameras.length === 0} onChange={(event) => void selectCamera(event.target.value)}>
                {cameras.length === 0 && <option value="">Default camera</option>}
                {cameras.map((device, index) => <option key={device.deviceId || `camera-${index}`} value={device.deviceId}>{device.label || `Camera ${index + 1}`}</option>)}
              </select>
            </div>}
          </div>
          <div className="audio-call-actions">
            <button className={`button compact ${microphoneEnabled ? "primary" : "ghost"}`} type="button" aria-pressed={microphoneEnabled} disabled={phase !== "connected"} onClick={() => void toggleMicrophone()}>{microphoneEnabled ? "Mute microphone" : "Unmute microphone"}</button>
            {joinedKind === "video" && <button className={`button compact ${cameraEnabled ? "primary" : "ghost"}`} type="button" aria-pressed={cameraEnabled} disabled={phase !== "connected"} onClick={() => void toggleCamera()}>{cameraEnabled ? "Turn camera off" : "Turn camera on"}</button>}
            {joinedKind === "video" && <button className={`button compact ${screenShareEnabled ? "primary" : "ghost"}`} type="button" aria-pressed={screenShareEnabled} disabled={phase !== "connected"} onClick={() => void toggleScreenShare()}>{screenShareEnabled ? "Stop sharing screen" : "Share screen"}</button>}
            <button className="button danger compact" type="button" disabled={phase === "leaving"} onClick={() => void leave()}>Leave call</button>
            {call?.can_end && <button className="button danger compact" type="button" disabled={phase === "leaving"} onClick={() => void endForEveryone()}>End for everyone</button>}
          </div>
          <div ref={remoteAudioRef} className="remote-audio-tracks" aria-hidden="true" />
        </section>,
        document.body
      )}

      {!joined && phase === "ended" && error && createPortal(
        <div className={`audio-call-terminal-notice ${accessRevoked ? "error" : ""}`} role={accessRevoked ? "alert" : "status"}>
          <strong>{accessRevoked ? `${mediaLabel(currentMediaKind)} access revoked` : `${mediaLabel(currentMediaKind)} call ended`}</strong>
          <span>{error}</span>
          {call?.can_end && <button className="button danger compact" type="button" onClick={() => void endForEveryone()}>End for everyone</button>}
        </div>,
        document.body
      )}

      {!joined && phase === "error" && error && createPortal(
        <div className="audio-call-terminal-notice error" role="alert">
          <strong>{mediaLabel(currentMediaKind)} call unavailable</strong>
          <span>{error}</span>
          {call?.can_end && <button className="button danger compact" type="button" onClick={() => void endForEveryone()}>End for everyone</button>}
        </div>,
        document.body
      )}
    </div>
  );
}

function CallActions({
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
  return <button className={`button compact ${active ? "audio-call-active" : "ghost"}`} type="button" disabled={disabled} aria-haspopup="dialog" onClick={() => onOpen(kind)}><span aria-hidden="true">{kind === "video" ? "▣" : "◖"}</span>{label}</button>;
}

function CallPrejoinDialog({
  kind,
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
    <section ref={dialogRef} className="modal-dialog audio-prejoin-dialog call-prejoin-dialog" role="dialog" aria-modal="true" aria-labelledby="call-prejoin-title" tabIndex={-1}>
      <span className="eyebrow">{kind === "video" ? "Camera and microphone" : "Audio only"}</span>
      <h2 id="call-prejoin-title">{title}</h2>
      <p>{kind === "video" ? "Choose exactly which devices to publish before entering. Camera preview stays on this device until you join." : "Choose whether to publish your microphone. Camera and screen sharing stay off."}</p>
      {error && <div className="form-error" role="alert">{error}</div>}
      {kind === "video" && <div className={`camera-preview ${cameraEnabled ? "enabled" : ""}`}>
        {cameraEnabled ? <video ref={previewVideoRef} data-k-comms-camera-preview autoPlay muted playsInline aria-label="Camera preview" /> : <div className="camera-preview-placeholder" aria-hidden="true">Camera off</div>}
        {previewBusy && <span className="camera-preview-status" role="status">Starting camera preview…</span>}
      </div>}
      <div className="prejoin-consent-grid">
        <label className="checkbox-field"><input type="checkbox" checked={microphoneEnabled} disabled={joining} onChange={(event) => onMicrophoneEnabled(event.target.checked)} />Use microphone when I join</label>
        {kind === "video" && <label className="checkbox-field"><input type="checkbox" checked={cameraEnabled} disabled={joining || previewBusy} onChange={(event) => onCameraEnabled(event.target.checked)} />Use camera when I join</label>}
      </div>
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
      <div className="form-actions audio-prejoin-actions">
        <button className="button ghost" type="button" data-initial-focus onClick={onCancel}>Cancel</button>
        {kind === "audio" ? <>
          <button className="button ghost" type="button" disabled={joining} onClick={() => onJoin(false, false)}>{joining ? "Joining…" : "Join muted"}</button>
          <button className="button primary" type="button" disabled={joining} onClick={() => onJoin(true, false)}>{joining ? "Joining…" : "Join with microphone"}</button>
        </> : <button className="button primary" type="button" disabled={joining || previewBusy} onClick={() => onJoin(microphoneEnabled, cameraEnabled)}>{joining ? "Joining…" : "Join video call"}</button>}
      </div>
    </section>
  </div>;
}

function VideoParticipantGrid({ participants }: { participants: ParticipantView[] }) {
  return <div className={`video-participant-grid participant-count-${Math.min(participants.length, 4)}`} role="list" aria-label="Video participants">
    {participants.map((participant) => <article className={`video-participant-tile ${participant.speaking ? "speaking" : ""}`} role="listitem" key={participant.id} data-participant-id={participant.id}>
      <div className="video-track-stack">
        {participant.videoTracks.length > 0
          ? participant.videoTracks.map((video) => <VideoTrackElement key={video.id} video={video} participant={participant} />)
          : <div className="video-placeholder" aria-hidden="true"><span>{initials(participant.name)}</span><small>Camera off</small></div>}
      </div>
      <div className="video-participant-caption"><strong>{participant.name}{participant.local ? " (you)" : ""}</strong><span aria-label={`${participant.microphoneEnabled ? "Microphone on" : "Muted"}; ${participant.cameraEnabled ? "Camera on" : "Camera off"}`}>{participant.microphoneEnabled ? "●" : "○"} {participant.cameraEnabled ? "Camera on" : "Camera off"}</span></div>
    </article>)}
  </div>;
}

function VideoTrackElement({ video, participant }: { video: VideoTrackView; participant: ParticipantView }) {
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
  return <div ref={containerRef} className={`video-track-frame ${video.source === "screen_share" ? "screen-share" : "camera"}`}><span className="visually-hidden">{participant.name} {video.source === "screen_share" ? "screen share" : "camera"}</span></div>;
}

function participantVideoTracks(participant: Participant): VideoTrackView[] {
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

function microphoneCaptureOptions(deviceId: string) {
  return { ...(deviceId ? { deviceId } : {}), echoCancellation: true, noiseSuppression: true, autoGainControl: true };
}

function cameraCaptureOptions(deviceId: string) {
  return { ...(deviceId ? { deviceId } : {}), resolution: { width: 1280, height: 720, frameRate: 30 }, facingMode: "user" as const };
}

function cameraConstraints(deviceId: string): MediaTrackConstraints {
  return { ...(deviceId ? { deviceId: { exact: deviceId } } : {}), width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30, max: 30 } };
}

function mediaBoundaryError(kind: "microphone" | "camera"): string | null {
  if (window.isSecureContext === false) return `${kind === "camera" ? "Camera" : "Microphone"} access requires a secure HTTPS connection.`;
  if (!navigator.mediaDevices?.getUserMedia) return `This browser does not provide ${kind} access.`;
  return null;
}

function mediaErrorText(reason: unknown, kind: "microphone" | "camera" | "screen" | "device"): string {
  const label = kind === "screen" ? "screen sharing" : kind === "device" ? "media device" : kind;
  if (reason instanceof DOMException) {
    if (reason.name === "NotAllowedError" || reason.name === "SecurityError") return `${capitalize(label)} permission was blocked. Allow access in browser and operating-system settings, then try again.`;
    if (reason.name === "NotFoundError" || reason.name === "OverconstrainedError") return `No available ${label} matches the selected device. Choose another device and try again.`;
    if (reason.name === "NotReadableError" || reason.name === "AbortError") return `The ${label} could not be opened. Close other applications using it, then try again.`;
  }
  return errorText(reason);
}

function callMediaKind(call: Pick<Call, "media_kind">): CallMediaKind {
  return call?.media_kind === "video" ? "video" : "audio";
}

function mediaEnabled(kind: CallMediaKind, audioEnabled: boolean, videoEnabled: boolean) {
  return kind === "video" ? videoEnabled : audioEnabled;
}

function mediaLabel(kind: CallMediaKind) {
  return kind === "video" ? "Video" : "Audio";
}

function deviceSelection(current: string, devices: MediaDeviceInfo[]) {
  return devices.some(({ deviceId }) => deviceId === current) ? current : devices[0]?.deviceId || "";
}

function initials(name: string) {
  return name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]?.toUpperCase() || "").join("") || "?";
}

function capitalize(value: string) {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function clearRemoteAudio(container: HTMLDivElement | null) {
  container?.querySelectorAll("[data-k-comms-call-audio]").forEach((element) => element.remove());
}

type CompatibilityApi = ApiClient & Partial<{
  audioCall: (conversationId: string) => Promise<Call | null>;
  startAudioCall: (conversationId: string) => Promise<CallSessionResponse>;
  joinAudioCall: (conversationId: string, callId: string) => Promise<CallSessionResponse>;
  endAudioCall: (conversationId: string, callId: string) => Promise<Call>;
}>;

function getCall(api: CompatibilityApi, conversationId: string) {
  if (typeof api.call === "function") return api.call(conversationId);
  if (typeof api.audioCall === "function") return api.audioCall(conversationId);
  throw new Error("Call status is not supported by this client.");
}

function startNewCall(api: CompatibilityApi, conversationId: string, mediaKind: CallMediaKind) {
  if (typeof api.startCall === "function") return api.startCall(conversationId, mediaKind);
  if (mediaKind === "audio" && typeof api.startAudioCall === "function") return api.startAudioCall(conversationId);
  throw new Error(`${mediaLabel(mediaKind)} calls are not supported by this client.`);
}

function joinExistingCall(api: CompatibilityApi, conversationId: string, callId: string) {
  if (typeof api.joinCall === "function") return api.joinCall(conversationId, callId);
  if (typeof api.joinAudioCall === "function") return api.joinAudioCall(conversationId, callId);
  throw new Error("Joining calls is not supported by this client.");
}

function endExistingCall(api: CompatibilityApi, conversationId: string, callId: string) {
  if (typeof api.endCall === "function") return api.endCall(conversationId, callId);
  if (typeof api.endAudioCall === "function") return api.endAudioCall(conversationId, callId);
  throw new Error("Ending calls is not supported by this client.");
}
