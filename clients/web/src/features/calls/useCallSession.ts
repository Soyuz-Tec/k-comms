import { useCallback, useEffect, useRef, useState } from "react";
import {
  ConnectionState,
  DisconnectReason,
  Room,
  RoomEvent
} from "livekit-client";
import type { Participant } from "livekit-client";
import { useModalDialog } from "../../components/useModalDialog";
import { errorText } from "../../lib/format";
import type { Call, CallMediaKind, CallRealtimeEvent, Conversation } from "../../types";
import { CALL_SESSION_TEARDOWN_EVENT } from "./callSessionEvents";
import type { CallApi, CallPanelSessionState, CallPhase } from "./callContracts";
import type { ParticipantView } from "./CallPanelViews";
import {
  callMediaKind,
  callPublishDefaults,
  callRtcConfig,
  cameraCaptureOptions,
  deviceSelection,
  endExistingCall,
  getCall,
  joinExistingCall,
  mediaBoundaryError,
  mediaEnabled,
  mediaErrorText,
  mediaLabel,
  microphoneCaptureOptions,
  participantVideoTracks,
  startNewCall
} from "./callMedia";
import { useLiveKitRoom } from "./useLiveKitRoom";
import { useMediaDevices } from "./useMediaDevices";

type CallWorkspaceTab = "chat" | "people" | "files";

const CALL_CONTROL_LABELS_STORAGE_KEY = "k-comms.call-control-labels.v1";

function storedCallControlLabelsVisible(): boolean {
  try {
    return window.localStorage.getItem(CALL_CONTROL_LABELS_STORAGE_KEY) !== "hidden";
  } catch {
    return true;
  }
}

export interface CallPanelProps {
  api: CallApi;
  conversation: Conversation;
  audioEnabled: boolean;
  videoEnabled: boolean;
  currentUserDisplayName: string;
  realtimeEvent?: CallRealtimeEvent | null;
  showVideoAction?: boolean;
  launchRequest?: CallMediaKind | null;
  launchRequestId?: number;
  onLaunchRequestConsumed?: () => void;
  renderActions?: boolean;
  onNavigate?: (path: string) => void;
  onOpenChat?: () => void;
  onSessionStateChange?: (state: CallPanelSessionState) => void;
}

export function useCallSession({
  api,
  conversation,
  audioEnabled,
  videoEnabled,
  currentUserDisplayName,
  realtimeEvent,
  launchRequest,
  launchRequestId,
  onLaunchRequestConsumed,
  onNavigate,
  onOpenChat,
  onSessionStateChange
}: CallPanelProps) {
  const available = audioEnabled || videoEnabled;
  const [call, setCall] = useState<Call | null>(null);
  const [phase, setPhase] = useState<CallPhase>(available ? "loading" : "idle");
  const [prejoinKind, setPrejoinKind] = useState<CallMediaKind>("audio");
  const [error, setError] = useState<string | null>(null);
  const [microphoneEnabled, setMicrophoneEnabled] = useState(false);
  const [cameraEnabled, setCameraEnabled] = useState(false);
  const [screenShareEnabled, setScreenShareEnabled] = useState(false);
  const [audioBlocked, setAudioBlocked] = useState(false);
  const [videoBlocked, setVideoBlocked] = useState(false);
  const [participants, setParticipants] = useState<ParticipantView[]>([]);
  const [callWorkspaceTab, setCallWorkspaceTab] = useState<CallWorkspaceTab>("chat");
  const [mobileWorkspaceOpen, setMobileWorkspaceOpen] = useState(false);
  const [endConfirmationOpen, setEndConfirmationOpen] = useState(false);
  const [callControlLabelsVisible, setCallControlLabelsVisible] = useState(
    storedCallControlLabelsVisible
  );
  const [labelPreferenceAnnouncement, setLabelPreferenceAnnouncement] = useState("");
  const [accessRevoked, setAccessRevoked] = useState(false);
  const [minimized, setMinimized] = useState(false);
  const [mobileCallLayout, setMobileCallLayout] = useState(
    () => window.matchMedia?.("(max-width: 760px), (max-height: 560px)").matches ?? false
  );
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const {
    attachRemoteAudio,
    clearAllRemoteAudio,
    disconnectRoom,
    manualDisconnectRoomsRef,
    remoteAudioRef,
    removeRemoteAudio,
    roomRef
  } = useLiveKitRoom();
  const roomMediaKindRef = useRef<CallMediaKind | null>(null);
  const pendingMediaKindRef = useRef<CallMediaKind | null>(null);
  const callMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const callMenuOpenerRef = useRef<HTMLButtonElement | null>(null);
  const mountedRef = useRef(true);
  const operationGenerationRef = useRef(0);
  const refreshSequenceRef = useRef(0);
  const accessRevokedRef = useRef(false);
  const latestRealtimeEventRef = useRef<CallRealtimeEvent | null>(null);
  const handledLaunchRequestRef = useRef<number | CallMediaKind | null>(null);
  const wasJoinedRef = useRef(false);
  const {
    cameras,
    loadPrejoinDevices,
    microphones,
    prejoinCamera,
    prejoinMicrophone,
    previewBusy,
    previewVideoRef,
    selectedCamera,
    selectedMicrophone,
    selectPrejoinCamera,
    setCameras,
    setMicrophones,
    setPrejoinCamera,
    setPrejoinMicrophone,
    setSelectedCamera,
    setSelectedMicrophone,
    stopPreview,
    togglePrejoinCamera
  } = useMediaDevices({ mountedRef, setError });
  const currentCallId = call?.id;
  const currentMediaKind = call ? callMediaKind(call) : prejoinKind;
  const joined = Boolean(roomRef.current) && ["connected", "reconnecting", "leaving"].includes(phase);
  const joinedKind = roomMediaKindRef.current || currentMediaKind;
  const expandedCallModal = joined && !minimized && (
    mobileCallLayout || joinedKind === "video"
  );
  function openMobileCallMenu(opener: HTMLButtonElement) {
    callMenuOpenerRef.current = opener;
    setMobileWorkspaceOpen(true);
  }
  function closeMobileCallMenu() {
    const opener = callMenuOpenerRef.current ?? callMenuTriggerRef.current;
    setMobileWorkspaceOpen(false);
    window.requestAnimationFrame(() => {
      if (opener?.isConnected && !opener.inert) {
        opener.focus({ preventScroll: true });
      }
      callMenuOpenerRef.current = null;
    });
  }
  function toggleCallControlLabels() {
    setCallControlLabelsVisible((visible) => {
      const next = !visible;
      try {
        window.localStorage.setItem(
          CALL_CONTROL_LABELS_STORAGE_KEY,
          next ? "visible" : "hidden"
        );
      } catch {
        // A blocked preference store must not interfere with call controls.
      }
      setLabelPreferenceAnnouncement(
        next ? "Control labels shown" : "Control labels hidden"
      );
      return next;
    });
  }
  const callWorkspaceRef = useModalDialog(
    closeMobileCallMenu,
    mobileCallLayout && mobileWorkspaceOpen && !minimized
  );
  const callDockRef = useModalDialog(() => {
    if (mobileWorkspaceOpen) {
      closeMobileCallMenu();
      return;
    }
    setMinimized(true);
  }, expandedCallModal);
  const endConfirmationRef = useModalDialog(
    () => setEndConfirmationOpen(false),
    endConfirmationOpen
  );
  function openConversationChat() {
    setCallWorkspaceTab("chat");
    setMobileWorkspaceOpen(false);
    setMinimized(true);
    if (onNavigate) {
      onNavigate(`/app/?conversation=${encodeURIComponent(conversation.id)}`);
    } else {
      onOpenChat?.();
    }
  }

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia("(max-width: 760px), (max-height: 560px)");
    const update = () => setMobileCallLayout(query.matches);
    update();
    query.addEventListener?.("change", update);
    return () => query.removeEventListener?.("change", update);
  }, []);

  const invalidateOperations = useCallback(() => {
    refreshSequenceRef.current += 1;
    operationGenerationRef.current += 1;
    return operationGenerationRef.current;
  }, []);

  const operationIsCurrent = useCallback((generation: number) => (
    mountedRef.current && operationGenerationRef.current === generation
  ), []);

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
  }, [disconnectRoom, invalidateOperations, stopPreview]);

  useEffect(() => {
    const teardownForPageExit = (event: Event) => {
      invalidateOperations();
      stopPreview();
      const room = roomRef.current;
      roomRef.current = null;
      roomMediaKindRef.current = null;
      pendingMediaKindRef.current = null;
      if (room) void disconnectRoom(room);
      clearAllRemoteAudio();
      if (event.type === CALL_SESSION_TEARDOWN_EVENT && mountedRef.current) {
        resetConnectedState();
        setCall(null);
        setError(null);
        setPhase("idle");
      }
    };
    window.addEventListener("pagehide", teardownForPageExit);
    window.addEventListener("beforeunload", teardownForPageExit);
    window.addEventListener(CALL_SESSION_TEARDOWN_EVENT, teardownForPageExit);
    return () => {
      window.removeEventListener("pagehide", teardownForPageExit);
      window.removeEventListener("beforeunload", teardownForPageExit);
      window.removeEventListener(CALL_SESSION_TEARDOWN_EVENT, teardownForPageExit);
    };
  }, [disconnectRoom, invalidateOperations, stopPreview]);

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

  const openPrejoin = useCallback(async (requestedKind: CallMediaKind) => {
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
    void loadPrejoinDevices(
      kind,
      () => operationIsCurrent(generation) && !roomRef.current
    );
  }, [
    audioEnabled,
    call,
    loadPrejoinDevices,
    operationIsCurrent,
    phase,
    refreshCall,
    stopPreview,
    videoEnabled
  ]);

  useEffect(() => {
    if (!launchRequest) {
      handledLaunchRequestRef.current = null;
      return;
    }
    const requestKey = launchRequestId ?? launchRequest;
    if (handledLaunchRequestRef.current === requestKey) return;
    if (phase !== "idle" && phase !== "ended") return;

    handledLaunchRequestRef.current = requestKey;
    onLaunchRequestConsumed?.();
    if (!mediaEnabled(launchRequest, audioEnabled, videoEnabled)) {
      setError(`${mediaLabel(launchRequest)} calls are disabled for this workspace.`);
      return;
    }
    void openPrejoin(launchRequest);
  }, [audioEnabled, launchRequest, launchRequestId, onLaunchRequestConsumed, openPrejoin, phase, videoEnabled]);

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
        videoCaptureDefaults: cameraCaptureOptions(cameraDeviceId),
        publishDefaults: callPublishDefaults(),
        ...callRtcConfig(response.credential.ice_servers)
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
    room.on(RoomEvent.LocalTrackUnpublished, (publication) => {
      publication.track?.stop();
      update();
    });
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

  function resetConnectedState() {
    setParticipants([]);
    setCallWorkspaceTab("chat");
    setMobileWorkspaceOpen(false);
    setEndConfirmationOpen(false);
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

  async function reloadDevices(kind: CallMediaKind) {
    const room = roomRef.current;
    const generation = operationGenerationRef.current;
    if (!room) return;
    try {
      const [audioDevices, videoDevices] = await Promise.all([
        Room.getLocalDevices("audioinput", false),
        kind === "video" ? Room.getLocalDevices("videoinput", false) : Promise.resolve([])
      ]);
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
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
    const generation = operationGenerationRef.current;
    try {
      const switched = await room.switchActiveDevice("audioinput", deviceId, true);
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      if (!switched) throw new Error("The selected microphone could not be activated.");
      setError(null);
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      setSelectedMicrophone(previousDeviceId);
      setError(mediaErrorText(reason, "microphone"));
    }
  }

  async function selectCamera(deviceId: string) {
    const previousDeviceId = selectedCamera;
    setSelectedCamera(deviceId);
    const room = roomRef.current;
    if (!room || !cameraEnabled) return;
    const generation = operationGenerationRef.current;
    try {
      const switched = await room.switchActiveDevice("videoinput", deviceId, true);
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      if (!switched) throw new Error("The selected camera could not be activated.");
      setError(null);
      updateRoomState(room);
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      setSelectedCamera(previousDeviceId);
      setError(mediaErrorText(reason, "camera"));
    }
  }

  async function toggleMicrophone() {
    const room = roomRef.current;
    if (!room) return;
    const generation = operationGenerationRef.current;
    setError(null);
    try {
      if (!microphoneEnabled) {
        const boundaryError = mediaBoundaryError("microphone");
        if (boundaryError) throw new Error(boundaryError);
        const devices = await Room.getLocalDevices("audioinput", true);
        if (!operationIsCurrent(generation) || roomRef.current !== room) return;
        setMicrophones(devices);
        const deviceId = selectedMicrophone || devices[0]?.deviceId || "";
        if (!deviceId) throw new Error("No microphone was found.");
        setSelectedMicrophone(deviceId);
        await room.localParticipant.setMicrophoneEnabled(true, microphoneCaptureOptions(deviceId));
      } else {
        await room.localParticipant.setMicrophoneEnabled(false);
      }
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      updateRoomState(room);
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      setError(mediaErrorText(reason, "microphone"));
    }
  }

  async function toggleCamera() {
    const room = roomRef.current;
    if (!room || roomMediaKindRef.current !== "video") return;
    const generation = operationGenerationRef.current;
    setError(null);
    try {
      if (!cameraEnabled) {
        const boundaryError = mediaBoundaryError("camera");
        if (boundaryError) throw new Error(boundaryError);
        const devices = await Room.getLocalDevices("videoinput", true);
        if (!operationIsCurrent(generation) || roomRef.current !== room) return;
        setCameras(devices);
        const deviceId = selectedCamera || devices[0]?.deviceId || "";
        if (!deviceId) throw new Error("No camera was found.");
        setSelectedCamera(deviceId);
        await room.localParticipant.setCameraEnabled(true, cameraCaptureOptions(deviceId));
      } else {
        await room.localParticipant.setCameraEnabled(false);
      }
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      updateRoomState(room);
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      setError(mediaErrorText(reason, "camera"));
    }
  }

  async function toggleScreenShare() {
    const room = roomRef.current;
    if (!room || roomMediaKindRef.current !== "video") return;
    const generation = operationGenerationRef.current;
    setError(null);
    try {
      await room.localParticipant.setScreenShareEnabled(!screenShareEnabled, {
        audio: false,
        video: true,
        selfBrowserSurface: "exclude",
        surfaceSwitching: "include"
      });
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      updateRoomState(room);
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      setError(mediaErrorText(reason, "screen"));
    }
  }

  async function enablePlayback() {
    const room = roomRef.current;
    if (!room) return;
    const generation = operationGenerationRef.current;
    const kind = roomMediaKindRef.current;
    try {
      await room.startAudio();
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      if (kind === "video") await room.startVideo();
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      setAudioBlocked(!room.canPlaybackAudio);
      setVideoBlocked(kind === "video" && !room.canPlaybackVideo);
      setError(null);
    } catch (reason: unknown) {
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
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

  useEffect(() => {
    if (
      (phase !== "connected" && phase !== "reconnecting") ||
      !currentCallId
    ) return;
    let current = true;
    let checking = false;

    const verifyActiveCall = async () => {
      const room = roomRef.current;
      if (!current || checking || !room) return;
      checking = true;
      try {
        const activeCall = await getCall(api, conversation.id);
        if (!current || roomRef.current !== room) return;
        if (activeCall?.id === currentCallId && activeCall.status === "active") {
          setCall(activeCall);
          return;
        }

        const kind = roomMediaKindRef.current || currentMediaKind;
        const generation = invalidateOperations();
        stopPreview();
        roomRef.current = null;
        roomMediaKindRef.current = null;
        pendingMediaKindRef.current = null;
        await disconnectRoom(room);
        if (!operationIsCurrent(generation)) return;
        clearAllRemoteAudio();
        resetConnectedState();
        setCall(null);
        setError(`The ${kind} call was ended for everyone.`);
        setPhase("ended");
      } catch {
        // The media provider remains authoritative during a transient API
        // failure. Its disconnect/revocation events still tear down capture.
      } finally {
        checking = false;
      }
    };

    const verifyWhenVisible = () => {
      if (document.visibilityState === "visible") void verifyActiveCall();
    };
    const timer = window.setInterval(verifyWhenVisible, 15_000);
    window.addEventListener("focus", verifyWhenVisible);
    document.addEventListener("visibilitychange", verifyWhenVisible);
    return () => {
      current = false;
      window.clearInterval(timer);
      window.removeEventListener("focus", verifyWhenVisible);
      document.removeEventListener("visibilitychange", verifyWhenVisible);
    };
  }, [
    api,
    conversation.id,
    currentCallId,
    currentMediaKind,
    disconnectRoom,
    invalidateOperations,
    operationIsCurrent,
    phase,
    stopPreview
  ]);

  useEffect(() => {
    if (!joined) {
      wasJoinedRef.current = false;
      setMinimized(false);
      setElapsedSeconds(0);
      return;
    }
    if (wasJoinedRef.current) return;
    wasJoinedRef.current = true;
    setMinimized(joinedKind === "audio" && !mobileCallLayout);
    const frame = window.requestAnimationFrame(() => {
      callDockRef.current?.querySelector<HTMLElement>("[data-call-focus]")?.focus({
        preventScroll: true
      });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [joined, joinedKind, mobileCallLayout]);

  useEffect(() => {
    if (joined && joinedKind === "audio" && mobileCallLayout) {
      setMinimized(false);
    }
  }, [joined, joinedKind, mobileCallLayout]);

  useEffect(() => {
    if (!joined) return;
    const startedAt = call?.started_at ? Date.parse(call.started_at) : Date.now();
    const update = () => setElapsedSeconds(Math.max(0, Math.floor((Date.now() - startedAt) / 1_000)));
    update();
    const timer = window.setInterval(update, 1_000);
    return () => window.clearInterval(timer);
  }, [call?.started_at, joined]);
  const activeKind = call?.status === "active" ? callMediaKind(call) : null;

  useEffect(() => {
    onSessionStateChange?.({
      conversationId: conversation.id,
      callId: currentCallId || null,
      phase,
      mediaKind: joinedKind,
      joined,
      microphoneEnabled,
      cameraEnabled,
      screenShareEnabled,
      canEnd: call?.can_end === true,
      accessRevoked
    });
  }, [
    accessRevoked,
    call?.can_end,
    cameraEnabled,
    conversation.id,
    currentCallId,
    joined,
    joinedKind,
    microphoneEnabled,
    onSessionStateChange,
    phase,
    screenShareEnabled
  ]);

  return {
    accessRevoked,
    activeKind,
    audioBlocked,
    available,
    call,
    callControlLabelsVisible,
    callDockRef,
    callMenuTriggerRef,
    callWorkspaceRef,
    callWorkspaceTab,
    cameraEnabled,
    cameras,
    closeMobileCallMenu,
    currentMediaKind,
    elapsedSeconds,
    enablePlayback,
    endConfirmationOpen,
    endConfirmationRef,
    endForEveryone,
    error,
    expandedCallModal,
    join,
    joined,
    joinedKind,
    labelPreferenceAnnouncement,
    leave,
    microphoneEnabled,
    microphones,
    minimized,
    mobileCallLayout,
    mobileWorkspaceOpen,
    openConversationChat,
    openMobileCallMenu,
    openPrejoin,
    participants,
    phase,
    prejoinCamera,
    prejoinKind,
    prejoinMicrophone,
    previewBusy,
    previewVideoRef,
    remoteAudioRef,
    screenShareEnabled,
    selectCamera,
    selectedCamera,
    selectedMicrophone,
    selectMicrophone,
    selectPrejoinCamera,
    setCallWorkspaceTab,
    setEndConfirmationOpen,
    setMinimized,
    setMobileWorkspaceOpen,
    setPrejoinMicrophone,
    setSelectedMicrophone,
    toggleCallControlLabels,
    toggleCamera,
    toggleMicrophone,
    togglePrejoinCamera,
    toggleScreenShare,
    videoBlocked
  };
}
