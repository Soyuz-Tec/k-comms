import { useCallback, useEffect, useRef, useState } from "react";
import {
  ConnectionState,
  DisconnectReason,
  Room,
  RoomEvent
} from "livekit-client";
import { errorText } from "../../lib/format";
import {
  RealtimeCall,
  socketEndpoint,
  type DirectAudioConfiguration,
  type DirectAudioPeer,
  type DirectAudioSignalEvent
} from "../../realtime";
import type { Call, CallMediaKind, CallRealtimeEvent, Conversation } from "../../types";
import { CALL_SESSION_TEARDOWN_EVENT } from "./callSessionEvents";
import type { CallApi, CallPanelSessionState, CallPhase } from "./callContracts";
import {
  callMediaKind,
  callPublishDefaults,
  callRtcConfig,
  cameraCaptureOptions,
  deviceSelection,
  endExistingCall,
  joinExistingCall,
  mediaBoundaryError,
  mediaEnabled,
  mediaErrorText,
  mediaLabel,
  microphoneCaptureOptions,
  startNewCall
} from "./callMedia";
import { useCallPresentationState } from "./useCallPresentationState";
import { useCallControlPlane } from "./useCallControlPlane";
import { useCallMediaSession } from "./useCallMediaSession";
import { useCallReadinessTest } from "./useCallReadinessTest";
import type { CallReadinessMode } from "./callReadinessNavigation";
import {
  DirectAudioTransport,
  type DirectAudioSignal
} from "./directAudioTransport";
import { DirectSignalQueue } from "./directSignalQueue";

export type CallTransportMode = "livekit" | "connecting_direct" | "direct" | "livekit_fallback";
type DirectSignalingState = "idle" | "negotiating" | "connected" | "fallback";

export interface CallPanelProps {
  api: CallApi;
  conversation: Conversation;
  audioEnabled: boolean;
  videoEnabled: boolean;
  currentUserDisplayName: string;
  currentUserId?: string;
  realtimeEvent?: CallRealtimeEvent | null;
  showVideoAction?: boolean;
  launchRequest?: CallMediaKind | null;
  launchRequestId?: number;
  launchReadinessMode?: CallReadinessMode | null;
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
  currentUserId = "",
  realtimeEvent,
  launchRequest,
  launchRequestId,
  launchReadinessMode,
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
  const [accessRevoked, setAccessRevoked] = useState(false);
  const mountedRef = useRef(true);
  const operationGenerationRef = useRef(0);
  const refreshSequenceRef = useRef(0);
  const accessRevokedRef = useRef(false);
  const latestRealtimeEventRef = useRef<CallRealtimeEvent | null>(null);
  const handledLaunchRequestRef = useRef<number | CallMediaKind | null>(null);
  const callRealtimeRef = useRef<RealtimeCall | null>(null);
  const directTransportRef = useRef<DirectAudioTransport | null>(null);
  const directConfigurationRef = useRef<DirectAudioConfiguration | null>(null);
  const directPeersRef = useRef<DirectAudioPeer[]>([]);
  const directRemotePeerIdRef = useRef<string | null>(null);
  const pendingDirectSignalsRef = useRef(new DirectSignalQueue<DirectAudioSignalEvent>());
  const directSignalingStateRef = useRef<DirectSignalingState>("idle");
  const directStartAttemptRef = useRef(false);
  const desiredMicrophoneRef = useRef(false);
  const [preferDirectAudio, setPreferDirectAudio] = useState(false);
  const [directMicrophoneEnabled, setDirectMicrophoneEnabled] = useState(false);
  const [directRemoteMicrophoneEnabled, setDirectRemoteMicrophoneEnabled] = useState(false);
  const [transportMode, setTransportMode] = useState<CallTransportMode>("livekit");
  const [raisedUserIds, setRaisedUserIds] = useState<Set<string>>(() => new Set());
  const [callReactions, setCallReactions] = useState<Array<{ id: string; userId: string; emoji: string }>>([]);
  const {
    attachRemoteAudio,
    audioBlocked,
    cameraEnabled,
    cameras,
    clearAllRemoteAudio,
    disconnectRoom,
    loadPrejoinDevices,
    manualDisconnectRoomsRef,
    microphoneEnabled,
    microphones,
    participants: livekitParticipants,
    pendingMediaKindRef,
    prejoinCamera,
    prejoinMicrophone,
    previewBusy,
    previewVideoRef,
    remoteAudioRef,
    removeRemoteAudio,
    resetMediaState,
    roomMediaKindRef,
    roomRef,
    screenShareEnabled,
    selectedCamera,
    selectedMicrophone,
    selectedSpeaker,
    selectPrejoinCamera,
    setCameras,
    setMicrophones,
    setPrejoinCamera,
    setPrejoinMicrophone,
    setSelectedCamera,
    setSelectedMicrophone,
    setSelectedSpeaker,
    setSpeakers,
    speakers,
    setAudioBlocked,
    setVideoBlocked,
    stopPreview,
    togglePrejoinCamera,
    updateRoomState,
    videoBlocked
  } = useCallMediaSession({
    currentUserDisplayName,
    mountedRef,
    setError
  });
  const callReadiness = useCallReadinessTest({
    microphoneEnabled,
    participants: livekitParticipants,
    roomRef
  });
  const {
    beginTransportQualification: beginCallReadinessTransport,
    enabled: callReadinessEnabled,
    fail: failCallReadiness,
    recordUnexpectedReconnect: recordCallReadinessReconnect,
    reset: resetCallReadiness,
    runPreflight: runCallReadinessPreflight,
    setEnabled: setCallReadinessEnabled
  } = callReadiness;
  const currentCallId = call?.id;
  const currentMediaKind = call ? callMediaKind(call) : prejoinKind;
  const joined = Boolean(roomRef.current) && ["connected", "reconnecting", "leaving"].includes(phase);
  const joinedKind = roomMediaKindRef.current || currentMediaKind;
  const presentation = useCallPresentationState({
    callStartedAt: call?.started_at,
    conversationId: conversation.id,
    joined,
    joinedKind,
    onNavigate,
    onOpenChat
  });

  const effectiveMicrophoneEnabled =
    transportMode === "direct" || transportMode === "connecting_direct"
      ? directMicrophoneEnabled
      : microphoneEnabled;
  const participants = livekitParticipants.map((participant) => {
    if (transportMode !== "direct") return participant;
    if (participant.local) {
      return { ...participant, microphoneEnabled: directMicrophoneEnabled };
    }
    if (participant.userId === conversation.counterpart_user_id) {
      return { ...participant, microphoneEnabled: directRemoteMicrophoneEnabled };
    }
    return participant;
  });

  const stopDirectAudio = useCallback((nextMode: CallTransportMode = "livekit") => {
    directTransportRef.current?.stop();
    directTransportRef.current = null;
    directConfigurationRef.current = null;
    directPeersRef.current = [];
    directRemotePeerIdRef.current = null;
    pendingDirectSignalsRef.current.clear();
    directSignalingStateRef.current = "idle";
    directStartAttemptRef.current = false;
    setDirectMicrophoneEnabled(false);
    setDirectRemoteMicrophoneEnabled(false);
    setTransportMode(nextMode);
  }, []);

  const invalidateOperations = useCallback(() => {
    refreshSequenceRef.current += 1;
    operationGenerationRef.current += 1;
    return operationGenerationRef.current;
  }, []);

  const operationIsCurrent = useCallback((generation: number) => (
    mountedRef.current && operationGenerationRef.current === generation
  ), []);

  const resetConnectedState = useCallback(() => {
    presentation.setCallWorkspaceTab("chat");
    presentation.setMobileWorkspaceOpen(false);
    presentation.setEndConfirmationOpen(false);
    resetMediaState();
    resetCallReadiness(false);
    stopDirectAudio();
    setPreferDirectAudio(false);
  }, [
    presentation.setCallWorkspaceTab,
    presentation.setEndConfirmationOpen,
    presentation.setMobileWorkspaceOpen,
    resetCallReadiness,
    resetMediaState,
    stopDirectAudio
  ]);

  const dismissTerminalNotice = useCallback(() => {
    setError(null);
  }, []);

  const disconnectEndedCall = useCallback(async (
    room: Room,
    kind: CallMediaKind
  ) => {
    const generation = invalidateOperations();
    stopPreview();
    roomRef.current = null;
    roomMediaKindRef.current = null;
    pendingMediaKindRef.current = null;
    await disconnectRoom(room);
    callRealtimeRef.current?.disconnect();
    callRealtimeRef.current = null;
    if (!operationIsCurrent(generation)) return;
    clearAllRemoteAudio();
    resetConnectedState();
    setCall(null);
    setError(`The ${kind} call was ended for everyone.`);
    setPhase("ended");
  }, [
    clearAllRemoteAudio,
    disconnectRoom,
    invalidateOperations,
    operationIsCurrent,
    resetConnectedState,
    roomRef,
    stopPreview
  ]);

  const { refreshCall } = useCallControlPlane({
    accessRevokedRef,
    api,
    available,
    conversationId: conversation.id,
    currentCallId,
    currentMediaKind,
    disconnectEndedCall,
    latestRealtimeEventRef,
    operationGenerationRef,
    operationIsCurrent,
    phase,
    roomRef,
    refreshSequenceRef,
    setCall,
    setError,
    setPhase,
    setPrejoinKind
  });

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
      callRealtimeRef.current?.disconnect();
      callRealtimeRef.current = null;
      directTransportRef.current?.stop();
      directTransportRef.current = null;
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
      callRealtimeRef.current?.disconnect();
      callRealtimeRef.current = null;
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
    callRealtimeRef.current?.disconnect();
    callRealtimeRef.current = null;
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
    callRealtimeRef.current?.disconnect();
    callRealtimeRef.current = null;
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

  const openPrejoin = useCallback(async (
    requestedKind: CallMediaKind,
    readinessMode: CallReadinessMode | null = null
  ) => {
    if (accessRevokedRef.current || roomRef.current) return;
    if (phase === "error") {
      setPhase("loading");
      await refreshCall();
      return;
    }
    const kind = call?.status === "active" ? callMediaKind(call) : requestedKind;
    if (!mediaEnabled(kind, audioEnabled, videoEnabled)) return;
    const readinessEnabled = kind === "audio" && readinessMode === "office";
    const generation = operationGenerationRef.current;
    pendingMediaKindRef.current = kind;
    setPrejoinKind(kind);
    setCallReadinessEnabled(readinessEnabled);
    if (kind !== "audio" || conversation.kind !== "direct" || readinessEnabled) {
      setPreferDirectAudio(false);
    }
    setPrejoinMicrophone(readinessEnabled);
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
    conversation.kind,
    loadPrejoinDevices,
    operationIsCurrent,
    phase,
    refreshCall,
    setCallReadinessEnabled,
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
    void openPrejoin(launchRequest, launchReadinessMode);
  }, [audioEnabled, launchReadinessMode, launchRequest, launchRequestId, onLaunchRequestConsumed, openPrejoin, phase, videoEnabled]);

  async function join(options: { publishMicrophone: boolean; publishCamera: boolean }) {
    if (accessRevokedRef.current) return;
    const kind = call?.status === "active" ? callMediaKind(call) : prejoinKind;
    if (!mediaEnabled(kind, audioEnabled, videoEnabled)) return;
    const readinessEnabled = kind === "audio" && callReadinessEnabled;
    const publishMicrophone = readinessEnabled || options.publishMicrophone;
    const directAudioRequested =
      kind === "audio" && conversation.kind === "direct" && !readinessEnabled && preferDirectAudio;
    desiredMicrophoneRef.current = publishMicrophone;
    setDirectMicrophoneEnabled(publishMicrophone);
    setTransportMode("livekit");
    if (readinessEnabled) resetCallReadiness(true);
    const generation = invalidateOperations();
    pendingMediaKindRef.current = kind;
    stopPreview();
    const previousRoom = roomRef.current;
    callRealtimeRef.current?.disconnect();
    callRealtimeRef.current = null;
    setRaisedUserIds(new Set());
    setCallReactions([]);
    roomRef.current = null;
    roomMediaKindRef.current = null;
    if (previousRoom) void disconnectRoom(previousRoom);

    let microphoneDeviceId = selectedMicrophone;
    let cameraDeviceId = selectedCamera;
    if (publishMicrophone) {
      const boundaryError = mediaBoundaryError("microphone");
      if (boundaryError) {
        if (readinessEnabled) failCallReadiness(boundaryError);
        setError(boundaryError);
        return;
      }
      try {
        const devices = await Room.getLocalDevices("audioinput", true);
        if (!operationIsCurrent(generation)) return;
        if (devices.length === 0) throw new Error("No microphone was found.");
        microphoneDeviceId = microphoneDeviceId || devices[0]?.deviceId || "";
        setMicrophones(devices);
        setSelectedMicrophone(microphoneDeviceId);
      } catch (reason: unknown) {
        if (operationIsCurrent(generation)) {
          const message = mediaErrorText(reason, "microphone");
          if (readinessEnabled) failCallReadiness(message);
          setError(message);
        }
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

      if (readinessEnabled) {
        await runCallReadinessPreflight(
          response.credential.server_url,
          response.credential.participant_token
        );
        if (!operationIsCurrent(generation)) return;
      }

      room = new Room({
        adaptiveStream: true,
        dynacast: true,
        audioCaptureDefaults: microphoneCaptureOptions(microphoneDeviceId),
        videoCaptureDefaults: cameraCaptureOptions(cameraDeviceId),
        publishDefaults: callPublishDefaults(),
        ...callRtcConfig(
          response.credential.ice_servers,
          readinessEnabled ? "relay" : undefined
        )
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
      if (selectedSpeaker) {
        await room.switchActiveDevice("audiooutput", selectedSpeaker, true).catch(() => false);
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

      if (publishMicrophone) {
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
      if (readinessEnabled) void beginCallReadinessTransport(room);
      void connectCallRealtime(response.data.id, generation, room, {
        directAudioRequested,
        microphoneDeviceId,
        publishMicrophone
      });
    } catch (reason: unknown) {
      if (room) await disconnectRoom(room);
      if (roomRef.current === room) roomRef.current = null;
      roomMediaKindRef.current = null;
      pendingMediaKindRef.current = null;
      if (!operationIsCurrent(generation)) return;
      const message = `Unable to join the ${kind} call. ${errorText(reason)}`;
      if (readinessEnabled) failCallReadiness(message);
      setError(message);
      setPhase(readinessEnabled ? "prejoin" : "error");
    }
  }

  function bindRoom(room: Room, kind: CallMediaKind) {
    const update = () => {
      updateRoomState(room);
      const realtime = callRealtimeRef.current;
      if (directTransportRef.current && room.remoteParticipants.size !== 1) {
        if (realtime) {
          void fallbackDirectAudio(
            room,
            operationGenerationRef.current,
            realtime,
            true
          );
        }
      } else if (!directTransportRef.current && room.remoteParticipants.size === 1 && realtime) {
        void maybeStartDirectAudio(room, operationGenerationRef.current, realtime);
      }
    };
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
    room.on(RoomEvent.ConnectionQualityChanged, update);
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
      if (roomRef.current === room) {
        recordCallReadinessReconnect();
        setPhase("reconnecting");
      }
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
      callRealtimeRef.current?.disconnect();
      callRealtimeRef.current = null;
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

  async function reloadDevices(kind: CallMediaKind) {
    const room = roomRef.current;
    const generation = operationGenerationRef.current;
    if (!room) return;
    try {
      const [audioDevices, videoDevices, outputDevices] = await Promise.all([
        Room.getLocalDevices("audioinput", false),
        kind === "video" ? Room.getLocalDevices("videoinput", false) : Promise.resolve([]),
        Room.getLocalDevices("audiooutput", false).catch(() => [])
      ]);
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      setMicrophones(audioDevices);
      setSelectedMicrophone((current) => deviceSelection(current, audioDevices));
      setCameras(videoDevices);
      setSelectedCamera((current) => deviceSelection(current, videoDevices));
      setSpeakers(outputDevices);
      setSelectedSpeaker((current) => deviceSelection(current, outputDevices));
    } catch {
      // Retain the last known device list through transient browser changes.
    }
  }

  async function selectMicrophone(deviceId: string) {
    const previousDeviceId = selectedMicrophone;
    setSelectedMicrophone(deviceId);
    const room = roomRef.current;
    if (!room || !effectiveMicrophoneEnabled) return;
    const generation = operationGenerationRef.current;
    try {
      if (directTransportRef.current && transportMode === "direct") {
        await directTransportRef.current.switchMicrophone(deviceId);
        if (!operationIsCurrent(generation)) return;
        setError(null);
        return;
      }
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

  async function selectSpeaker(deviceId: string) {
    const previousDeviceId = selectedSpeaker;
    setSelectedSpeaker(deviceId);
    const room = roomRef.current;
    if (!room) return;
    try {
      if (directTransportRef.current && transportMode === "direct") {
        await directTransportRef.current.selectSpeaker(deviceId);
        setError(null);
        return;
      }
      const switched = await room.switchActiveDevice("audiooutput", deviceId, true);
      if (!switched) throw new Error("The selected speaker could not be activated.");
      setError(null);
    } catch (reason: unknown) {
      setSelectedSpeaker(previousDeviceId);
      setError(mediaErrorText(reason, "device"));
    }
  }

  async function fallbackDirectAudio(
    room: Room,
    generation: number,
    realtime: RealtimeCall,
    notifyRemote: boolean
  ) {
    if (directSignalingStateRef.current === "fallback") return;
    directSignalingStateRef.current = "fallback";
    const transport = directTransportRef.current;
    directTransportRef.current = null;
    if (notifyRemote && directRemotePeerIdRef.current) {
      void realtime.sendDirectSignal(directRemotePeerIdRef.current, { kind: "fallback" }).catch(() => undefined);
    }
    void realtime.disableDirectAudio().catch(() => undefined);
    transport?.stop();
    directConfigurationRef.current = null;
    directPeersRef.current = [];
    directRemotePeerIdRef.current = null;
    pendingDirectSignalsRef.current.clear();
    setTransportMode("livekit_fallback");
    setDirectMicrophoneEnabled(false);
    setDirectRemoteMicrophoneEnabled(false);

    if (!operationIsCurrent(generation) || roomRef.current !== room) return;
    try {
      await room.localParticipant.setMicrophoneEnabled(
        desiredMicrophoneRef.current,
        microphoneCaptureOptions(selectedMicrophone)
      );
      if (operationIsCurrent(generation) && roomRef.current === room) updateRoomState(room);
    } catch (reason: unknown) {
      if (operationIsCurrent(generation) && roomRef.current === room) {
        setError(`Direct audio could not fall back to the call service. ${mediaErrorText(reason, "microphone")}`);
      }
    }
  }

  async function maybeStartDirectAudio(room: Room, generation: number, realtime: RealtimeCall) {
    const configuration = directConfigurationRef.current;
    if (!configuration || directStartAttemptRef.current || !currentUserId || !conversation.counterpart_user_id) return;
    const localPeers = directPeersRef.current
      .filter((peer) => peer.userId === currentUserId)
      .sort((left, right) => left.peerId.localeCompare(right.peerId));
    const remotePeers = directPeersRef.current
      .filter((peer) => peer.userId === conversation.counterpart_user_id)
      .sort((left, right) => left.peerId.localeCompare(right.peerId));
    const localPeer = localPeers[0];
    const remotePeer = remotePeers[0];
    if (
      localPeers.length !== 1 ||
      remotePeers.length !== 1 ||
      room.remoteParticipants.size !== 1 ||
      !remotePeer ||
      localPeer?.peerId !== configuration.peerId
    ) return;

    directStartAttemptRef.current = true;
    directSignalingStateRef.current = "negotiating";
    directRemotePeerIdRef.current = remotePeer.peerId;
    setTransportMode("connecting_direct");
    setDirectMicrophoneEnabled(desiredMicrophoneRef.current);

    const transport = new DirectAudioTransport({
      iceServers: configuration.iceServers,
      audioHost: remoteAudioRef.current || document.body,
      onSignal: (signal) => {
        const remotePeerId = directRemotePeerIdRef.current;
        if (!remotePeerId) return;
        void realtime.sendDirectSignal(remotePeerId, signal).catch(() => {
          void fallbackDirectAudio(room, generation, realtime, false);
        });
      },
      onState: (state) => {
        if (directTransportRef.current !== transport) return;
        if (state === "connected") {
          directSignalingStateRef.current = "connected";
          setTransportMode("direct");
          const remotePeerId = directRemotePeerIdRef.current;
          if (remotePeerId) {
            void realtime.sendDirectSignal(remotePeerId, {
              kind: "media",
              enabled: desiredMicrophoneRef.current
            }).catch(() => undefined);
          }
        }
        if (state === "failed") void fallbackDirectAudio(room, generation, realtime, true);
      },
      onPlaybackBlocked: () => setAudioBlocked(true)
    });
    directTransportRef.current = transport;

    try {
      await room.localParticipant.setMicrophoneEnabled(false);
      if (!operationIsCurrent(generation) || roomRef.current !== room) {
        transport.stop();
        return;
      }
      updateRoomState(room);
      await transport.start(
        configuration.peerId,
        remotePeer.peerId,
        desiredMicrophoneRef.current,
        selectedMicrophone
      );
      const pendingSignals = pendingDirectSignalsRef.current.drain();
      for (const event of pendingSignals) {
        if (event.fromPeerId === remotePeer.peerId) {
          if (event.signal.kind === "media") {
            setDirectRemoteMicrophoneEnabled(event.signal.enabled);
          } else {
            await transport.handleSignal(event.signal as DirectAudioSignal);
          }
        }
      }
    } catch {
      await fallbackDirectAudio(room, generation, realtime, true);
    }
  }

  async function connectCallRealtime(
    callId: string,
    generation: number,
    room: Room,
    options: {
      directAudioRequested: boolean;
      microphoneDeviceId: string;
      publishMicrophone: boolean;
    }
  ) {
    if (!api.socketTicket) return;
    try {
      const { ticket } = await api.socketTicket();
      if (!operationIsCurrent(generation) || roomRef.current !== room) return;
      const realtime = new RealtimeCall(
        socketEndpoint(import.meta.env.VITE_API_BASE_URL || ""),
        ticket,
        callId,
        conversation.id,
        {
          onReady: (userIds) => setRaisedUserIds(new Set(userIds)),
          onHand: (userId, raised) => setRaisedUserIds((current) => {
            const next = new Set(current);
            if (raised) next.add(userId); else next.delete(userId);
            return next;
          }),
          onReaction: handleCallReaction,
          onParticipantMuted: (userId) => {
            if (userId === currentUserId) {
              desiredMicrophoneRef.current = false;
              setDirectMicrophoneEnabled(false);
            }
            if (directTransportRef.current) void fallbackDirectAudio(room, generation, realtime, false);
            if (roomRef.current) updateRoomState(roomRef.current);
          },
          onParticipantRemoved: () => {
            if (directTransportRef.current) void fallbackDirectAudio(room, generation, realtime, false);
            if (roomRef.current) updateRoomState(roomRef.current);
          },
          onDirectReady: (configuration) => {
            directConfigurationRef.current = configuration;
            if (configuration) {
              if (directSignalingStateRef.current !== "fallback") {
                directSignalingStateRef.current = "negotiating";
                void maybeStartDirectAudio(room, generation, realtime);
              }
            } else if (
              directSignalingStateRef.current === "negotiating" ||
              directSignalingStateRef.current === "connected"
            ) {
              void fallbackDirectAudio(room, generation, realtime, false);
            }
          },
          onDirectPeers: (peers) => {
            directPeersRef.current = peers;
            if (directTransportRef.current) {
              const localPeerCount = peers.filter((peer) => peer.userId === currentUserId).length;
              const remotePeerCount = peers.filter(
                (peer) => peer.userId === conversation.counterpart_user_id
              ).length;
              if (localPeerCount !== 1 || remotePeerCount !== 1) {
                void fallbackDirectAudio(room, generation, realtime, true);
                return;
              }
            }
            void maybeStartDirectAudio(room, generation, realtime);
          },
          onDirectSignal: (event) => {
            if (directSignalingStateRef.current === "fallback") return;
            if (
              event.signal.kind === "media" &&
              event.fromUserId === conversation.counterpart_user_id
            ) {
              setDirectRemoteMicrophoneEnabled(event.signal.enabled);
              return;
            }
            const transport = directTransportRef.current;
            if (!transport || !directRemotePeerIdRef.current) {
              if (
                directSignalingStateRef.current === "negotiating" &&
                !pendingDirectSignalsRef.current.enqueue(event)
              ) {
                void fallbackDirectAudio(room, generation, realtime, true);
              }
              return;
            }
            if (event.fromPeerId !== directRemotePeerIdRef.current) return;
            void transport.handleSignal(event.signal as DirectAudioSignal).catch(() => {
              void fallbackDirectAudio(room, generation, realtime, true);
            });
          },
          onDisconnected: () => {
            if (directTransportRef.current) {
              void fallbackDirectAudio(room, generation, realtime, false);
            }
          },
          onError: (message) => setError(message)
        },
        options.directAudioRequested
      );
      callRealtimeRef.current?.disconnect();
      callRealtimeRef.current = realtime;
      desiredMicrophoneRef.current = options.publishMicrophone;
      if (options.microphoneDeviceId) setSelectedMicrophone(options.microphoneDeviceId);
      realtime.connect();
    } catch (reason: unknown) {
      setError(`Call collaboration controls are unavailable. ${errorText(reason)}`);
    }
  }

  async function toggleHand() {
    const realtime = callRealtimeRef.current;
    if (!realtime) { setError("Call collaboration controls are reconnecting."); return; }
    const raised = !raisedUserIds.has(currentUserId);
    try { await realtime.setHand(raised); } catch (reason: unknown) { setError(errorText(reason)); }
  }

  async function sendCallReaction(emoji: string) {
    const realtime = callRealtimeRef.current;
    if (!realtime) { setError("Call collaboration controls are reconnecting."); return; }
    try { await realtime.react(emoji); } catch (reason: unknown) { setError(errorText(reason)); }
  }

  function handleCallReaction(event: { userId: string; emoji: string }) {
    const id = crypto.randomUUID();
    setCallReactions((current) => [...current.slice(-7), { id, userId: event.userId, emoji: event.emoji }]);
    window.setTimeout(() => {
      if (mountedRef.current) {
        setCallReactions((current) => current.filter((reaction) => reaction.id !== id));
      }
    }, 5_000);
  }

  async function muteParticipant(providerIdentity: string, trackSid: string) {
    if (!call || !api.muteCallParticipant) return;
    try { await api.muteCallParticipant(conversation.id, call.id, providerIdentity, trackSid); }
    catch (reason: unknown) { setError(`Unable to mute participant. ${errorText(reason)}`); }
  }

  async function removeParticipant(providerIdentity: string) {
    if (!call || !api.removeCallParticipant) return;
    try { await api.removeCallParticipant(conversation.id, call.id, providerIdentity); }
    catch (reason: unknown) { setError(`Unable to remove participant. ${errorText(reason)}`); }
  }

  async function toggleMicrophone() {
    const room = roomRef.current;
    if (!room) return;
    const generation = operationGenerationRef.current;
    setError(null);
    try {
      if (directTransportRef.current && (transportMode === "direct" || transportMode === "connecting_direct")) {
        const enabled = !directMicrophoneEnabled;
        if (enabled) {
          const boundaryError = mediaBoundaryError("microphone");
          if (boundaryError) throw new Error(boundaryError);
        }
        await directTransportRef.current.setMicrophoneEnabled(enabled);
        if (!operationIsCurrent(generation)) return;
        desiredMicrophoneRef.current = enabled;
        setDirectMicrophoneEnabled(enabled);
        const remotePeerId = directRemotePeerIdRef.current;
        if (remotePeerId) {
          void callRealtimeRef.current?.sendDirectSignal(remotePeerId, {
            kind: "media",
            enabled
          }).catch(() => undefined);
        }
        return;
      }
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
      desiredMicrophoneRef.current = !microphoneEnabled;
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
      if (directTransportRef.current && transportMode === "direct") {
        await directTransportRef.current.enablePlayback();
      }
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
    callRealtimeRef.current?.disconnect();
    callRealtimeRef.current = null;
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
      callRealtimeRef.current?.disconnect();
      callRealtimeRef.current = null;
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

  const activeKind = call?.status === "active" ? callMediaKind(call) : null;

  const setReadinessEnabled = useCallback((enabled: boolean) => {
    setCallReadinessEnabled(enabled);
    if (enabled) {
      setPrejoinMicrophone(true);
      setPreferDirectAudio(false);
    }
  }, [setCallReadinessEnabled, setPrejoinMicrophone]);

  useEffect(() => {
    onSessionStateChange?.({
      conversationId: conversation.id,
      callId: currentCallId || null,
      phase,
      mediaKind: joinedKind,
      joined,
      microphoneEnabled: effectiveMicrophoneEnabled,
      cameraEnabled,
      screenShareEnabled,
      canEnd: call?.can_end === true,
      accessRevoked,
      transportMode
    });
  }, [
    accessRevoked,
    call?.can_end,
    cameraEnabled,
    conversation.id,
    currentCallId,
    joined,
    joinedKind,
    effectiveMicrophoneEnabled,
    onSessionStateChange,
    phase,
    screenShareEnabled,
    transportMode
  ]);

  return {
    accessRevoked,
    activeKind,
    audioBlocked,
    available,
    call,
    callControlLabelsVisible: presentation.callControlLabelsVisible,
    callDockRef: presentation.callDockRef,
    callMenuTriggerRef: presentation.callMenuTriggerRef,
    callWorkspaceRef: presentation.callWorkspaceRef,
    callWorkspaceTab: presentation.callWorkspaceTab,
    cameraEnabled,
    cameras,
    closeMobileCallMenu: presentation.closeMobileCallMenu,
    currentMediaKind,
    dismissTerminalNotice,
    elapsedSeconds: presentation.elapsedSeconds,
    enablePlayback,
    endConfirmationOpen: presentation.endConfirmationOpen,
    endConfirmationRef: presentation.endConfirmationRef,
    endForEveryone,
    error,
    expandedCallModal: presentation.expandedCallModal,
    join,
    joined,
    joinedKind,
    labelPreferenceAnnouncement: presentation.labelPreferenceAnnouncement,
    leave,
    microphoneEnabled: effectiveMicrophoneEnabled,
    microphones,
    minimized: presentation.minimized,
    mobileCallLayout: presentation.mobileCallLayout,
    mobileWorkspaceOpen: presentation.mobileWorkspaceOpen,
    openConversationChat: presentation.openConversationChat,
    openMobileCallMenu: presentation.openMobileCallMenu,
    openPrejoin,
    participants,
    raisedUserIds,
    callReactions,
    callReadiness,
    phase,
    prejoinCamera,
    prejoinKind,
    prejoinMicrophone,
    preferDirectAudio,
    previewBusy,
    previewVideoRef,
    remoteAudioRef,
    screenShareEnabled,
    selectCamera,
    selectedCamera,
    selectedMicrophone,
    selectedSpeaker,
    selectMicrophone,
    selectSpeaker,
    selectPrejoinCamera,
    setCallWorkspaceTab: presentation.setCallWorkspaceTab,
    setEndConfirmationOpen: presentation.setEndConfirmationOpen,
    setMinimized: presentation.setMinimized,
    setMobileWorkspaceOpen: presentation.setMobileWorkspaceOpen,
    setPrejoinMicrophone,
    setPreferDirectAudio,
    setReadinessEnabled,
    setSelectedMicrophone,
    toggleCallControlLabels: presentation.toggleCallControlLabels,
    toggleCamera,
    toggleMicrophone,
    togglePrejoinCamera,
    toggleScreenShare,
    toggleHand,
    sendCallReaction,
    muteParticipant,
    removeParticipant,
    speakers,
    transportMode,
    videoBlocked
  };
}
