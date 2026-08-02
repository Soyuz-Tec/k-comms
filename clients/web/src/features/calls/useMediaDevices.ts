import { useCallback, useEffect, useRef, useState } from "react";
import { Room } from "livekit-client";
import type { CallMediaKind } from "../../types";
import {
  cameraConstraints,
  mediaBoundaryError,
  mediaErrorText
} from "./callMedia";

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
  const [selectedMicrophone, setSelectedMicrophone] = useState("");
  const [selectedCamera, setSelectedCamera] = useState("");
  const [selectedSpeaker, setSelectedSpeaker] = useState("");
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
      setMicrophones(audioDevices);
      setSelectedMicrophone((current) => current || audioDevices[0]?.deviceId || "");
      setCameras(videoDevices);
      setSelectedCamera((current) => current || videoDevices[0]?.deviceId || "");
      setSpeakers(outputDevices);
      setSelectedSpeaker((current) => current || outputDevices[0]?.deviceId || "");
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
