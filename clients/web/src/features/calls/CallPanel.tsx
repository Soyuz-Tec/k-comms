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
  Participant,
  RemoteTrack
} from "livekit-client";
import { AppIcon } from "../../components/AppIcon";
import {
  AppMenuCloseButton,
  AppMenuTrigger,
  AppSurfaceControlButton
} from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { errorText } from "../../lib/format";
import type {
  Call,
  CallMediaKind,
  CallRealtimeEvent,
  Conversation
} from "../../types";
import { CALL_SESSION_TEARDOWN_EVENT } from "./callSessionEvents";

import type {
  CallApi,
  CallPanelSessionState,
  CallPhase
} from "./callContracts";
import {
  AudioParticipantStage,
  CallActions,
  CallPrejoinDialog,
  prioritizeVideoParticipants,
  VideoParticipantGrid,
  type ParticipantView
} from "./CallPanelViews";
import {
  callMediaKind,
  callPublishDefaults,
  callRtcConfig,
  cameraCaptureOptions,
  cameraConstraints,
  clearRemoteAudio,
  deviceSelection,
  endExistingCall,
  formatCallDuration,
  getCall,
  joinExistingCall,
  mediaBoundaryError,
  mediaEnabled,
  mediaErrorText,
  mediaLabel,
  microphoneCaptureOptions,
  participantVideoTracks,
  startNewCall,
  stopRoomLocalTracks
} from "./callMedia";

export type {
  CallApi,
  CallPanelSessionState,
  CallPhase
} from "./callContracts";
export { callPublishDefaults, callRtcConfig } from "./callMedia";

type CallWorkspaceTab = "chat" | "people" | "files";

const CALL_CONTROL_LABELS_STORAGE_KEY = "k-comms.call-control-labels.v1";

function storedCallControlLabelsVisible(): boolean {
  try {
    return window.localStorage.getItem(CALL_CONTROL_LABELS_STORAGE_KEY) !== "hidden";
  } catch {
    return true;
  }
}

function initials(name: string): string {
  return name.trim().split(/\s+/).slice(0, 2)
    .map((part) => part[0]?.toUpperCase() || "")
    .join("") || "?";
}

interface CallPanelProps {
  api: CallApi;
  conversation: Conversation;
  audioEnabled: boolean;
  videoEnabled: boolean;
  currentUserDisplayName: string;
  realtimeEvent?: CallRealtimeEvent | null;
  /** Keeps the audio-only compatibility wrapper to one visible action. */
  showVideoAction?: boolean;
  /** Opens the default-off prejoin once for a validated cross-page request. */
  launchRequest?: CallMediaKind | null;
  launchRequestId?: number;
  onLaunchRequestConsumed?: () => void;
  /** Allows the app shell to own media while feature routes render launchers. */
  renderActions?: boolean;
  onNavigate?: (path: string) => void;
  /** Returns an instant-room guest to the composer without ending the call. */
  onOpenChat?: () => void;
  onSessionStateChange?: (state: CallPanelSessionState) => void;
}

export function CallPanel({
  api,
  conversation,
  audioEnabled,
  videoEnabled,
  currentUserDisplayName,
  realtimeEvent,
  showVideoAction = true,
  launchRequest,
  launchRequestId,
  onLaunchRequestConsumed,
  renderActions = true,
  onNavigate,
  onOpenChat,
  onSessionStateChange
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
  const roomRef = useRef<Room | null>(null);
  const roomMediaKindRef = useRef<CallMediaKind | null>(null);
  const pendingMediaKindRef = useRef<CallMediaKind | null>(null);
  const remoteAudioRef = useRef<HTMLDivElement | null>(null);
  const callMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const callMenuOpenerRef = useRef<HTMLButtonElement | null>(null);
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
  const handledLaunchRequestRef = useRef<number | CallMediaKind | null>(null);
  const wasJoinedRef = useRef(false);
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

  const disconnectRoom = useCallback(async (room: Room) => {
    manualDisconnectRoomsRef.current.add(room);
    if (roomRef.current === room) roomRef.current = null;
    stopRoomLocalTracks(room);
    await room.disconnect(true).catch(() => undefined);
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
  }, [audioEnabled, call, operationIsCurrent, phase, refreshCall, stopPreview, videoEnabled]);

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
  const callStatusLabel = phase === "reconnecting"
    ? "Reconnecting"
    : phase === "leaving"
      ? "Leaving"
      : "Connected";
  const participantCountLabel =
    `${participants.length} ${participants.length === 1 ? "participant" : "participants"}`;

  return (
    <div className="call-control audio-call-control">
      {renderActions && <CallActions
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
      />}

      {(phase === "prejoin" || phase === "joining") && createPortal(
        <CallPrejoinDialog
          kind={prejoinKind}
          conversationTitle={conversation.title || "Conversation"}
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
        <section
          ref={callDockRef}
          className={`call-dock audio-call-dock active-call-screen ${joinedKind === "video" ? "video-call-dock video-call-screen" : "audio-call-screen"} ${minimized ? "minimized" : ""}`}
          data-call-control-labels={callControlLabelsVisible ? "visible" : "hidden"}
          role={expandedCallModal ? "dialog" : "region"}
          aria-modal={expandedCallModal || undefined}
          aria-labelledby="call-title"
          tabIndex={expandedCallModal ? -1 : undefined}
        >
          <div className="audio-call-dock-heading">
            <div className={`call-heading-summary ${phase === "connected" ? "" : "has-call-status"}`}>
              <span className="eyebrow">{mediaLabel(joinedKind)} call</span>
              <h2 className="call-room-title" id="call-title">
                {conversation.title || "Conversation call"}
              </h2>
              <div className="call-progress-meta" aria-label="Call progress">
                <span className="call-progress-duration">
                  {formatCallDuration(elapsedSeconds)}
                </span>
                <span className="call-progress-separator" aria-hidden="true">·</span>
                <span
                  className="call-participant-count"
                  role="status"
                  aria-label={participantCountLabel}
                >
                  <span className="call-participant-count-visual" aria-hidden="true">
                    <span className="call-participant-count-number">
                      {participants.length}
                    </span>
                    <span className="call-participant-count-word">
                      {participants.length === 1 ? "participant" : "participants"}
                    </span>
                    <span className="call-participant-count-icon">
                      <AppIcon name="users" />
                    </span>
                  </span>
                </span>
                <span
                  className={`status-pill ${phase === "connected" ? "success call-status-connected" : "neutral"}`}
                  aria-live="polite"
                >
                  {callStatusLabel}
                </span>
              </div>
            </div>
            <div
              className="call-dock-heading-actions app-surface-control-cluster"
              role="group"
              aria-label="Call window controls"
            >
              <AppSurfaceControlButton
                className="button ghost compact"
                data-call-focus
                accessibleLabel={minimized ? "Show call" : "Minimize"}
                kind={minimized ? "expand" : "minimize"}
                label={minimized ? "Show call" : "Minimize"}
                aria-expanded={!minimized}
                aria-controls="active-call-details"
                onClick={() => {
                  setMobileWorkspaceOpen(false);
                  setMinimized((current) => !current);
                }}
              />
              {mobileCallLayout && !minimized && (
                <AppMenuTrigger
                  ref={callMenuTriggerRef}
                  className="button ghost compact call-menu-trigger"
                  accessibleLabel="Open call menu"
                  expanded={mobileWorkspaceOpen}
                  controls="call-workspace-sheet"
                  overlay
                  onClick={(event) => openMobileCallMenu(event.currentTarget)}
                />
              )}
            </div>
          </div>
          <div
            id="active-call-details"
            className="active-call-details"
            onPointerDown={(event) => {
              if (
                mobileCallLayout
                && mobileWorkspaceOpen
                && event.currentTarget === event.target
              ) {
                closeMobileCallMenu();
              }
            }}
          >
            <div className="call-capture-indicator" role="status" aria-label="Local capture status">
              <strong>Capture</strong>
              <span className={microphoneEnabled ? "active" : undefined}>
                Microphone {microphoneEnabled ? "on" : "off"}
              </span>
              {joinedKind === "video" && (
                <span className={cameraEnabled ? "active" : undefined}>
                  Camera {cameraEnabled ? "on" : "off"}
                </span>
              )}
              {joinedKind === "video" && (
                <span className={screenShareEnabled ? "active" : undefined}>
                  Screen {screenShareEnabled ? "shared" : "not shared"}
                </span>
              )}
            </div>
            <section
              ref={callWorkspaceRef}
              className={`call-workspace-sheet ${mobileWorkspaceOpen ? "mobile-open" : ""}`}
              id="call-workspace-sheet"
              role={mobileCallLayout && mobileWorkspaceOpen ? "dialog" : undefined}
              aria-modal={mobileCallLayout && mobileWorkspaceOpen ? "true" : undefined}
              aria-labelledby={mobileCallLayout && mobileWorkspaceOpen ? "call-menu-title" : undefined}
              aria-label="Call workspace"
              tabIndex={mobileCallLayout && mobileWorkspaceOpen ? -1 : undefined}
            >
              <p className="visually-hidden" role="status" aria-live="polite">
                {labelPreferenceAnnouncement}
              </p>
              {mobileCallLayout && mobileWorkspaceOpen && (
                <header className="call-menu-header">
                  <h3 id="call-menu-title">Call menu</h3>
                  <AppMenuCloseButton
                    data-initial-focus
                    accessibleLabel="Close call menu"
                    onClick={closeMobileCallMenu}
                  />
                </header>
              )}
              <nav className="call-collaboration-links" aria-label="Call workspace">
                <button type="button" aria-pressed={callWorkspaceTab === "chat"} onClick={() => {
                  if (onNavigate || onOpenChat) {
                    openConversationChat();
                  } else {
                    setCallWorkspaceTab("chat");
                  }
                }}>
                  <AppIcon name="message" />
                  Chat
                </button>
                <button type="button" aria-label={mobileCallLayout ? "People" : "Directory"} aria-pressed={callWorkspaceTab === "people"} onClick={() => {
                  setCallWorkspaceTab("people");
                  if (onNavigate && !mobileCallLayout) {
                    setMobileWorkspaceOpen(false);
                    setMinimized(true);
                    onNavigate("/app/directory");
                  }
                }}>
                  <AppIcon name="users" />
                  People ({participants.length})
                </button>
                {onNavigate && (
                  <button type="button" aria-pressed={callWorkspaceTab === "files"} onClick={() => {
                    setCallWorkspaceTab("files");
                    setMobileWorkspaceOpen(false);
                    setMinimized(true);
                    onNavigate("/app/files");
                  }}>
                    <AppIcon name="file" />
                    Files
                  </button>
                )}
              </nav>
              <div className="call-workspace-body">
                {callWorkspaceTab === "chat" && (
                  <>
                    <strong>{conversation.title || "Conversation"}</strong>
                    <span>
                      {onOpenChat
                        ? "Open the room conversation without ending the call."
                        : "Continue messaging while the call stays connected."}
                    </span>
                    {(onNavigate || onOpenChat) && (
                      <button type="button" onClick={openConversationChat}>
                        {onOpenChat && !onNavigate ? "Open room chat" : "Open chat"}
                      </button>
                    )}
                  </>
                )}
                {callWorkspaceTab === "people" && (
                  <ul className="call-workspace-people">
                    {participants.map((participant) => (
                      <li key={participant.id}>
                        <span aria-hidden="true">{initials(participant.name)}</span>
                        <strong>{participant.name}{participant.local ? " (you)" : ""}</strong>
                        <small>{participant.microphoneEnabled ? "Microphone on" : "Muted"}</small>
                      </li>
                    ))}
                  </ul>
                )}
                {callWorkspaceTab === "files" && onNavigate && (
                  <>
                    <strong>Shared files</strong>
                    <span>Open authorized conversation files without ending the call.</span>
                    <button type="button" onClick={() => {
                      setMobileWorkspaceOpen(false);
                      setMinimized(true);
                      onNavigate("/app/files");
                    }}>Open files</button>
                  </>
                )}
              </div>
              {mobileCallLayout && mobileWorkspaceOpen && (
                <div className="call-menu-secondary-actions">
                  <button
                    className="button ghost call-control-label-toggle"
                    type="button"
                    onClick={toggleCallControlLabels}
                  >
                    <AppIcon name={callControlLabelsVisible ? "eyeOff" : "eye"} />
                    {callControlLabelsVisible ? "Hide labels" : "Show labels"}
                  </button>
                  <button
                    className="button danger"
                    type="button"
                    disabled={phase === "leaving"}
                    onClick={() => void leave()}
                  >
                    <AppIcon name="phoneOff" />
                    Leave call
                  </button>
                  {call?.can_end && <button
                    className="button danger"
                    type="button"
                    disabled={phase === "leaving"}
                    onClick={() => setEndConfirmationOpen(true)}
                  >
                    <AppIcon name="phoneOff" />
                    End for everyone
                  </button>}
                </div>
              )}
            </section>
            <div className="call-stage">
              {error && <div className="form-error" role="alert">{error}</div>}
              {(audioBlocked || videoBlocked) && <div className="inline-notice" role="status"><span>Browser media playback is paused.</span><button className="button ghost compact" type="button" onClick={() => void enablePlayback()}>{joinedKind === "audio" ? "Enable call audio" : "Enable call media"}</button></div>}
              {joinedKind === "video" && (
                <VideoParticipantGrid
                  participants={prioritizeVideoParticipants(participants)}
                />
              )}
              {joinedKind === "audio" && (
                <AudioParticipantStage participants={participants} />
              )}
            </div>
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
              <button
                className={`button compact call-action-microphone ${microphoneEnabled ? "primary" : "ghost"}`}
                type="button"
                aria-label={microphoneEnabled ? "Mute microphone" : "Unmute microphone"}
                aria-pressed={microphoneEnabled}
                disabled={phase !== "connected"}
                onClick={() => void toggleMicrophone()}
              >
                <span className="call-action-glyph" aria-hidden="true">
                  <AppIcon name={microphoneEnabled ? "mic" : "micOff"} />
                </span>
                <span className="call-action-label">
                  {mobileCallLayout
                    ? "Mic"
                    : microphoneEnabled ? "Mute microphone" : "Unmute microphone"}
                </span>
              </button>
              {joinedKind === "video" && (
                <button
                  className={`button compact call-action-camera ${cameraEnabled ? "primary" : "ghost"}`}
                  type="button"
                  aria-label={cameraEnabled ? "Turn camera off" : "Turn camera on"}
                  aria-pressed={cameraEnabled}
                  disabled={phase !== "connected"}
                  onClick={() => void toggleCamera()}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name={cameraEnabled ? "video" : "videoOff"} />
                  </span>
                  <span className="call-action-label">
                    {mobileCallLayout
                      ? "Camera"
                      : cameraEnabled ? "Turn camera off" : "Turn camera on"}
                  </span>
                </button>
              )}
              {joinedKind === "video" && (
                <button
                  className={`button compact call-action-screen ${screenShareEnabled ? "primary" : "ghost"}`}
                  type="button"
                  aria-label={screenShareEnabled ? "Stop sharing screen" : "Share screen"}
                  aria-pressed={screenShareEnabled}
                  disabled={phase !== "connected"}
                  onClick={() => void toggleScreenShare()}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name={screenShareEnabled ? "screenShareOff" : "screenShare"} />
                  </span>
                  <span className="call-action-label">
                    {mobileCallLayout
                      ? "Screen"
                      : screenShareEnabled ? "Stop sharing screen" : "Share screen"}
                  </span>
                </button>
              )}
              {mobileCallLayout && (
                <button
                  className={`button compact call-action-people call-action-more ${mobileWorkspaceOpen && callWorkspaceTab === "people" ? "primary" : "ghost"}`}
                  type="button"
                  aria-label="People"
                  aria-expanded={mobileWorkspaceOpen && callWorkspaceTab === "people"}
                  aria-controls="call-workspace-sheet"
                  onClick={(event) => {
                    setCallWorkspaceTab("people");
                    openMobileCallMenu(event.currentTarget);
                  }}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name="users" />
                  </span>
                  <span className="call-action-label">People</span>
                </button>
              )}
              <button
                className="button danger compact call-action-leave"
                type="button"
                aria-label="Leave call"
                disabled={phase === "leaving"}
                onClick={() => void leave()}
              >
                <span className="call-action-glyph" aria-hidden="true">
                  <AppIcon name="phoneOff" />
                </span>
                <span className="call-action-label">
                  {mobileCallLayout ? "Leave" : "Leave call"}
                </span>
              </button>
              {call?.can_end && !mobileCallLayout && (
                <button
                  className="button danger compact call-action-end"
                  type="button"
                  disabled={phase === "leaving"}
                  onClick={() => setEndConfirmationOpen(true)}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name="phoneOff" />
                  </span>
                  <span className="call-action-label">End for everyone</span>
                </button>
              )}
            </div>
          </div>
          <div ref={remoteAudioRef} className="remote-audio-tracks" aria-hidden="true" />
        </section>,
        document.body
      )}

      {joined && endConfirmationOpen && call?.can_end && createPortal(
        <div
          className="modal-backdrop call-end-confirmation-backdrop"
          onPointerDown={(event) => {
            if (event.currentTarget === event.target) {
              setEndConfirmationOpen(false);
            }
          }}
        >
          <section
            ref={endConfirmationRef}
            className="modal-dialog call-end-confirmation-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="call-end-confirmation-title"
            aria-describedby="call-end-confirmation-description"
            tabIndex={-1}
          >
            <header className="app-dialog-heading">
              <h2 id="call-end-confirmation-title">End call for everyone?</h2>
              <AppSurfaceControlButton
                accessibleLabel="Close end call confirmation"
                kind="close"
                onClick={() => setEndConfirmationOpen(false)}
              />
            </header>
            <p id="call-end-confirmation-description">
              This ends the call for every participant. This action cannot be undone.
            </p>
            <div className="form-actions">
              <button
                className="button ghost"
                type="button"
                data-initial-focus
                onClick={() => setEndConfirmationOpen(false)}
              >
                Cancel
              </button>
              <button
                className="button danger"
                type="button"
                onClick={() => {
                  setEndConfirmationOpen(false);
                  void endForEveryone();
                }}
              >
                End for everyone
              </button>
            </div>
          </section>
        </div>,
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
