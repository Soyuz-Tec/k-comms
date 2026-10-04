import { useCallback, useEffect, useRef, useState } from "react";
import { Room } from "livekit-client";
import type { CallMediaKind } from "../../types";
import {
  cameraConstraints,
  deviceSelection,
  mediaBoundaryError,
  mediaErrorText
} from "./callMedia";
import { readMediaDevicePreference } from "./media-device-preferences";

interface UseMediaDevicesOptions {
  mountedRef: { current: boolean };
  setError: (error: string | null) => void;
}

export function useMediaDevices({
  mountedRef,
  setError
}: UseMediaDevicesOptions) {
  const [microphones, setMicrophones] = useState<MediaDeviceInfo[]>([]);
  const [cameras, setCameras] = useState<MediaDeviceInfo[]>([]);
  const [speakers, setSpeakers] = useState<MediaDeviceInfo[]>([]);
  const [initialPreferences] = useState(() => ({
    microphone: readMediaDevicePreference("microphone"),
    camera: readMediaDevicePreference("camera"),
    speaker: readMediaDevicePreference("speaker")
  }));
  const appliedPreferencesRef = useRef(initialPreferences);
  const [selectedMicrophone, setSelectedMicrophone] = useState(initialPreferences.microphone);
  const [selectedCamera, setSelectedCamera] = useState(initialPreferences.camera);
  const [selectedSpeaker, setSelectedSpeaker] = useState(initialPreferences.speaker);
  const [prejoinMicrophone, setPrejoinMicrophone] = useState(false);
  const [prejoinCamera, setPrejoinCamera] = useState(false);
  const [previewBusy, setPreviewBusy] = useState(false);
  const [previewStream, setPreviewStream] = useState<MediaStream | null>(null);
  const previewVideoRef = useRef<HTMLVideoElement | null>(null);
  const previewStreamRef = useRef<MediaStream | null>(null);
  const previewGenerationRef = useRef(0);

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
  }, [mountedRef]);

  useEffect(() => {
    if (previewVideoRef.current) previewVideoRef.current.srcObject = previewStream;
  }, [previewStream]);

  const loadPrejoinDevices = useCallback(async (
    kind: CallMediaKind,
    accept: () => boolean
  ) => {
    try {
      const [audioDevices, videoDevices, outputDevices] = await Promise.all([
        Room.getLocalDevices("audioinput", false).catch(() => []),
        kind === "video"
          ? Room.getLocalDevices("videoinput", false).catch(() => [])
          : Promise.resolve([]),
        Room.getLocalDevices("audiooutput", false).catch(() => [])
      ]);
      if (!accept()) return;
      const previousPreferences = appliedPreferencesRef.current;
      const savedPreferences = {
        microphone: readMediaDevicePreference("microphone"),
        camera: readMediaDevicePreference("camera"),
        speaker: readMediaDevicePreference("speaker")
      };
      // A CallPanel persists after a call ends. Apply settings changed elsewhere
      // when the next lobby opens, while preserving manual choices on repeated
      // enumeration and never applying a rejected active-call refresh.
      setMicrophones(audioDevices);
      setSelectedMicrophone((current) => deviceSelection(savedPreferences.microphone !== previousPreferences.microphone ? savedPreferences.microphone : current, audioDevices));
      setCameras(videoDevices);
      if (kind === "video") setSelectedCamera((current) => deviceSelection(savedPreferences.camera !== previousPreferences.camera ? savedPreferences.camera : current, videoDevices));
      setSpeakers(outputDevices);
      setSelectedSpeaker((current) => deviceSelection(savedPreferences.speaker !== previousPreferences.speaker ? savedPreferences.speaker : current, outputDevices));
      appliedPreferencesRef.current = { ...savedPreferences, camera: kind === "video" ? savedPreferences.camera : previousPreferences.camera };
    } catch {
      // Labels can remain unavailable until the user explicitly enables a device.
    }
  }, []);

  const startCameraPreview = useCallback(async (deviceId: string) => {
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
  }, [mountedRef, setError, stopPreview]);

  const togglePrejoinCamera = useCallback(async (enabled: boolean) => {
    setPrejoinCamera(enabled);
    if (!enabled) {
      stopPreview();
      return;
    }
    await startCameraPreview(selectedCamera);
  }, [selectedCamera, startCameraPreview, stopPreview]);

  const selectPrejoinCamera = useCallback(async (deviceId: string) => {
    setSelectedCamera(deviceId);
    if (prejoinCamera) await startCameraPreview(deviceId);
  }, [prejoinCamera, startCameraPreview]);

  return {
    cameras,
    loadPrejoinDevices,
    microphones,
    prejoinCamera,
    prejoinMicrophone,
    previewBusy,
    previewVideoRef,
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
    stopPreview,
    togglePrejoinCamera
  };
}
