import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useMediaDevices } from "../calls/useMediaDevices";
import { mediaBoundaryError, mediaErrorText } from "../calls/callMedia";
import { saveMediaDevicePreference } from "../calls/media-device-preferences";
import { phoneMediaIsBusy, subscribePhoneMediaBusy } from "../telephony/mediaOwnership";
import { callSessionIsBusy, useOptionalCallSession } from "../calls/CallSessionProvider";

interface MicrophoneTest {
  stream: MediaStream;
  context: AudioContext;
  frame?: number;
  released: boolean;
}

function releaseMicrophoneTest(test: MicrophoneTest) {
  if (test.released) return;
  test.released = true;
  if (test.frame !== undefined) cancelAnimationFrame(test.frame);
  test.stream.getAudioTracks().forEach((track) => { track.onended = null; });
  test.stream.getTracks().forEach((track) => track.stop());
  void test.context.close().catch(() => {});
}

export function AudioVideoSettings() {
  const mountedRef = useRef(true);
  const [error, setError] = useState<string | null>(null);
  const [microphonePending, setMicrophonePending] = useState(false);
  const [microphoneActive, setMicrophoneActive] = useState(false);
  const [level, setLevel] = useState(0);
  const [speakerActive, setSpeakerActive] = useState(false);
  const [speakerNotice, setSpeakerNotice] = useState<string | null>(null);
  const microphoneRef = useRef<MicrophoneTest | null>(null);
  const microphoneGeneration = useRef(0);
  const speakerRef = useRef<HTMLAudioElement | null>(null);
  const speakerUrlRef = useRef<string | null>(null);
  const speakerGeneration = useRef(0);
  const callSession = useOptionalCallSession();
  const devices = useMediaDevices({ mountedRef, setError });
  const { loadPrejoinDevices, stopPreview, setPrejoinCamera } = devices;

  const stopMicrophone = useCallback(() => {
    microphoneGeneration.current += 1;
    const test = microphoneRef.current;
    microphoneRef.current = null;
    if (test) releaseMicrophoneTest(test);
    if (mountedRef.current) {
      setMicrophoneActive(false);
      setMicrophonePending(false);
      setLevel(0);
    }
  }, []);

  const stopSpeaker = useCallback(() => {
    speakerGeneration.current += 1;
    speakerRef.current?.pause();
    speakerRef.current = null;
    if (speakerUrlRef.current) URL.revokeObjectURL(speakerUrlRef.current);
    speakerUrlRef.current = null;
    if (mountedRef.current) setSpeakerActive(false);
  }, []);

  const subscribePhoneOwnership = useCallback((onChange: () => void) => subscribePhoneMediaBusy(() => {
    if (phoneMediaIsBusy()) {
      stopMicrophone();
      stopSpeaker();
      stopPreview();
      setPrejoinCamera(false);
    }
    onChange();
  }), [stopMicrophone, stopSpeaker, stopPreview, setPrejoinCamera]);
  const phoneBusy = useSyncExternalStore(subscribePhoneOwnership, phoneMediaIsBusy, () => false);
  const inCall = phoneBusy || Boolean(callSession?.launchRequest) || callSessionIsBusy(callSession?.sessionState || null);

  useEffect(() => {
    mountedRef.current = true;
    void loadPrejoinDevices("video", () => mountedRef.current);
    return () => {
      mountedRef.current = false;
      stopMicrophone();
      stopSpeaker();
      stopPreview();
    };
  }, [loadPrejoinDevices, stopMicrophone, stopSpeaker, stopPreview]);

  useEffect(() => {
    if (!inCall) return;
    stopMicrophone();
    stopSpeaker();
    stopPreview();
    setPrejoinCamera(false);
  }, [inCall, stopMicrophone, stopSpeaker, stopPreview, setPrejoinCamera]);

  async function testMicrophone() {
    if (inCall || phoneMediaIsBusy()) return setError("Leave your current call before testing devices.");
    stopMicrophone();
    setError(null);
    const boundaryError = mediaBoundaryError("microphone");
    if (boundaryError) return setError(boundaryError);
    if (!window.AudioContext) return setError("This browser cannot measure microphone levels. Try another supported browser.");
    const generation = microphoneGeneration.current;
    setMicrophonePending(true);
    let stream: MediaStream | null = null;
    let ownedTest: MicrophoneTest | null = null;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          ...(devices.selectedMicrophone ? { deviceId: { exact: devices.selectedMicrophone } } : {}),
          echoCancellation: true,
          noiseSuppression: true
        },
        video: false
      });
      if (!mountedRef.current || generation !== microphoneGeneration.current || phoneMediaIsBusy()) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      const context = new AudioContext();
      const test: MicrophoneTest = { stream, context, released: false };
      ownedTest = test;
      microphoneRef.current = test;
      const analyser = context.createAnalyser();
      analyser.fftSize = 256;
      context.createMediaStreamSource(stream).connect(analyser);
      await context.resume();
      if (!mountedRef.current || generation !== microphoneGeneration.current) return;
      setMicrophonePending(false);
      setMicrophoneActive(true);
      const samples = new Uint8Array(analyser.fftSize);
      let lastUpdate = 0;
      function measure(time: number) {
        if (!mountedRef.current || generation !== microphoneGeneration.current) return;
        if (time - lastUpdate >= 80) {
          analyser.getByteTimeDomainData(samples);
          const mean = samples.reduce((sum, sample) => sum + (sample / 128 - 1) ** 2, 0) / samples.length;
          setLevel(Math.min(100, Math.round(Math.sqrt(mean) * 200)));
          lastUpdate = time;
        }
        test.frame = requestAnimationFrame(measure);
      }
      test.frame = requestAnimationFrame(measure);
      stream.getAudioTracks().forEach((track) => {
        track.onended = () => {
          if (microphoneRef.current === test && generation === microphoneGeneration.current) stopMicrophone();
        };
      });
      void loadPrejoinDevices("video", () => mountedRef.current && generation === microphoneGeneration.current);
    } catch (reason: unknown) {
      const currentRequest = mountedRef.current && generation === microphoneGeneration.current;
      if (ownedTest) {
        if (microphoneRef.current === ownedTest) microphoneRef.current = null;
        releaseMicrophoneTest(ownedTest);
      } else {
        stream?.getTracks().forEach((track) => track.stop());
      }
      if (!currentRequest) return;
      stopMicrophone();
      setError(mediaErrorText(reason, "microphone"));
    }
  }

  async function testSpeaker() {
    if (inCall || phoneMediaIsBusy()) return setError("Leave your current call before testing devices.");
    stopSpeaker();
    setError(null);
    setSpeakerNotice(null);
    const generation = speakerGeneration.current;
    try {
      const audio = new Audio();
      const url = URL.createObjectURL(speakerTestTone());
      speakerUrlRef.current = url;
      speakerRef.current = audio;
      audio.src = url;
      audio.onended = stopSpeaker;
      if (devices.selectedSpeaker && typeof audio.setSinkId === "function") {
        await audio.setSinkId(devices.selectedSpeaker);
      } else if (devices.selectedSpeaker) {
        setSpeakerNotice("This browser uses your system's default speaker for the test.");
      }
      if (!mountedRef.current || generation !== speakerGeneration.current) return;
      await audio.play();
      if (mountedRef.current && generation === speakerGeneration.current) setSpeakerActive(true);
    } catch (reason: unknown) {
      if (!mountedRef.current || generation !== speakerGeneration.current) return;
      stopSpeaker();
      setError(mediaErrorText(reason, "device"));
    }
  }

  return <div className="settings-card audio-video-settings">
    <div className="card-heading"><h2>Audio &amp; video</h2></div>
    <p>Choose devices for your next call in this browser. Tests stay on this device and stop when you leave this section.</p>
    {inCall && <p role="status">Leave your current call before testing devices. Use the call's device controls while connected.</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    <DevicePicker label="Microphone" devices={devices.microphones} value={devices.selectedMicrophone} disabled={microphonePending || microphoneActive} onChange={(value) => { devices.setSelectedMicrophone(value); saveMediaDevicePreference("microphone", value); }} />
    <p className="media-test-state">{microphoneActive ? "Microphone is capturing for this local test." : microphonePending ? "Waiting for microphone permission…" : "Microphone is not capturing."}</p>
    <meter aria-label="Microphone level" min={0} max={100} value={level} />
    <div className="form-actions">
      <button className="button secondary" type="button" disabled={inCall} onClick={() => microphoneActive || microphonePending ? stopMicrophone() : void testMicrophone()}>{microphoneActive || microphonePending ? "Stop microphone test" : "Test microphone"}</button>
    </div>
    <DevicePicker label="Speaker" devices={devices.speakers} value={devices.selectedSpeaker} onChange={(value) => { stopSpeaker(); devices.setSelectedSpeaker(value); saveMediaDevicePreference("speaker", value); }} />
    <div className="form-actions"><button className="button secondary" type="button" disabled={inCall} onClick={() => speakerActive ? stopSpeaker() : void testSpeaker()}>{speakerActive ? "Stop speaker test" : "Test speaker"}</button></div>
    {speakerNotice && <p className="support-note" role="status">{speakerNotice}</p>}
    <DevicePicker label="Camera" devices={devices.cameras} value={devices.selectedCamera} disabled={devices.previewBusy} onChange={(value) => {
      saveMediaDevicePreference("camera", value);
      if (inCall || phoneMediaIsBusy()) { devices.setSelectedCamera(value); return; }
      void devices.selectPrejoinCamera(value);
    }} />
    <div className="camera-test-preview">
      {devices.prejoinCamera && <video ref={devices.previewVideoRef} autoPlay playsInline muted aria-label="Local camera preview" />}
      {!devices.prejoinCamera && <span>Camera preview is off.</span>}
    </div>
    <div className="form-actions"><button className="button secondary" type="button" disabled={inCall || devices.previewBusy} onClick={() => {
      if (inCall || phoneMediaIsBusy()) { setError("Leave your current call before testing devices."); return; }
      void devices.togglePrejoinCamera(!devices.prejoinCamera);
    }}>{devices.previewBusy ? "Opening camera…" : devices.prejoinCamera ? "Stop camera preview" : "Start camera preview"}</button></div>
    <p className="support-note">Device names may appear after you allow access. If permission is blocked, allow it in your browser and operating-system settings, then try again. An unavailable saved device falls back to an available device.</p>
  </div>;
}

function DevicePicker({ label, devices, value, disabled, onChange }: { label: string; devices: MediaDeviceInfo[]; value: string; disabled?: boolean; onChange: (value: string) => void }) {
  return <label className="field">{label}<select value={value} disabled={disabled} onChange={(event) => onChange(event.target.value)}>
    {devices.length === 0 && <option value="">Browser default</option>}
    {devices.map((device, index) => <option key={device.deviceId || `${label}-${index}`} value={device.deviceId}>{device.label || `${label} ${index + 1}`}</option>)}
  </select></label>;
}

function speakerTestTone(): Blob {
  const sampleRate = 44_100;
  const count = Math.round(sampleRate * .7);
  const bytes = new ArrayBuffer(44 + count * 2);
  const view = new DataView(bytes);
  function text(offset: number, value: string) {
    for (let index = 0; index < value.length; index++) view.setUint8(offset + index, value.charCodeAt(index));
  }
  text(0, "RIFF"); view.setUint32(4, bytes.byteLength - 8, true); text(8, "WAVE");
  text(12, "fmt "); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true); view.setUint32(28, sampleRate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  text(36, "data"); view.setUint32(40, count * 2, true);
  for (let index = 0; index < count; index++) {
    const fade = Math.min(1, index / 441, (count - index) / 441);
    view.setInt16(44 + index * 2, Math.sin(2 * Math.PI * 440 * index / sampleRate) * 3276 * fade, true);
  }
  return new Blob([bytes], { type: "audio/wav" });
}
