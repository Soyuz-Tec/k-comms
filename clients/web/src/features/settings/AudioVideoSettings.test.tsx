import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { setPhoneMediaBusy } from "../telephony/mediaOwnership";
import { AudioVideoSettings } from "./AudioVideoSettings";

const harness = vi.hoisted(() => ({
  getUserMedia: vi.fn(),
  play: vi.fn(),
  pause: vi.fn(),
  close: vi.fn(),
  sink: vi.fn(),
  inCall: false,
  devices: [
    { kind: "audioinput", deviceId: "mic-1", label: "Desk microphone" },
    { kind: "audiooutput", deviceId: "speaker-1", label: "Headphones" },
    { kind: "videoinput", deviceId: "camera-1", label: "Desk camera" }
  ]
}));

vi.mock("livekit-client", async (original) => ({
  ...await original<Record<string, unknown>>(),
  Room: { getLocalDevices: (kind: string) => Promise.resolve(harness.devices.filter((device) => device.kind === kind)) }
}));
vi.mock("../calls/CallSessionProvider", () => ({
  useOptionalCallSession: () => null,
  callSessionIsBusy: () => harness.inCall
}));

function stream(kind: "audio" | "video") {
  const track = { stop: vi.fn(), getSettings: () => ({ deviceId: kind === "audio" ? "mic-1" : "camera-1" }), onended: null };
  return { track, value: { getTracks: () => [track], getAudioTracks: () => kind === "audio" ? [track] : [], getVideoTracks: () => kind === "video" ? [track] : [] } };
}

describe("AudioVideoSettings", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.localStorage.clear();
    harness.inCall = false;
    setPhoneMediaBusy(false);
    harness.play.mockResolvedValue(undefined);
    harness.close.mockResolvedValue(undefined);
    harness.sink.mockResolvedValue(undefined);
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia: harness.getUserMedia } });
    vi.stubGlobal("AudioContext", class {
      close = harness.close;
      resume = () => Promise.resolve();
      createAnalyser = () => ({ fftSize: 256, getByteTimeDomainData: (array: Uint8Array) => array.fill(128) });
      createMediaStreamSource = () => ({ connect: vi.fn() });
    });
    vi.stubGlobal("Audio", class {
      src = "";
      onended = null;
      play = harness.play;
      pause = harness.pause;
      setSinkId = harness.sink;
    });
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:local-device-test");
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  });

  afterEach(() => { setPhoneMediaBusy(false); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("lists devices without requesting capture or playing sound", async () => {
    render(<AudioVideoSettings />);
    expect(await screen.findByRole("option", { name: "Desk microphone" })).toBeInTheDocument();
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
    expect(screen.getByText("Camera preview is off.")).toBeVisible();
    expect(harness.getUserMedia).not.toHaveBeenCalled();
    expect(harness.play).not.toHaveBeenCalled();
  });

  it("captures only after explicit microphone testing and releases it on Stop", async () => {
    const microphone = stream("audio");
    harness.getUserMedia.mockResolvedValue(microphone.value);
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await screen.findByRole("option", { name: "Desk microphone" });
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    expect(await screen.findByText("Microphone is capturing for this local test.")).toBeVisible();
    expect(harness.getUserMedia).toHaveBeenCalledWith({ audio: { deviceId: { exact: "mic-1" }, echoCancellation: true, noiseSuppression: true }, video: false });
    await user.click(screen.getByRole("button", { name: "Stop microphone test" }));
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
  });

  it("releases a late permission response when the settings section closes", async () => {
    let resolve!: (value: unknown) => void;
    harness.getUserMedia.mockImplementation(() => new Promise((done) => { resolve = done; }));
    const user = userEvent.setup();
    const view = render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    view.unmount();
    const microphone = stream("audio");
    resolve(microphone.value);
    await waitFor(() => expect(microphone.track.stop).toHaveBeenCalledOnce());
  });

  it("shows recoverable permission guidance and never claims capture after denial", async () => {
    harness.getUserMedia.mockRejectedValue(new DOMException("Permission denied", "NotAllowedError"));
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("permission was blocked");
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
    expect(screen.getByRole("button", { name: "Test microphone" })).toBeEnabled();
  });

  it("stops camera capture when the section closes", async () => {
    const camera = stream("video");
    harness.getUserMedia.mockResolvedValue(camera.value);
    const user = userEvent.setup();
    const view = render(<AudioVideoSettings />);
    await screen.findByRole("option", { name: "Desk camera" });
    await user.click(screen.getByRole("button", { name: "Start camera preview" }));
    expect(await screen.findByLabelText("Local camera preview")).toBeVisible();
    expect(harness.getUserMedia).toHaveBeenCalledWith(expect.objectContaining({ audio: false }));
    view.unmount();
    expect(camera.track.stop).toHaveBeenCalledOnce();
  });

  it("plays a local tone only on request and releases it when leaving settings", async () => {
    const user = userEvent.setup();
    const view = render(<AudioVideoSettings />);
    await screen.findByRole("option", { name: "Headphones" });
    await user.click(screen.getByRole("button", { name: "Test speaker" }));
    await waitFor(() => expect(harness.play).toHaveBeenCalledOnce());
    expect(harness.sink).toHaveBeenCalledWith("speaker-1");
    expect(harness.getUserMedia).not.toHaveBeenCalled();
    view.unmount();
    expect(harness.pause).toHaveBeenCalled();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:local-device-test");
  });

  it("keeps device tests unavailable while connected to a call", async () => {
    harness.inCall = true;
    render(<AudioVideoSettings />);
    expect(screen.getByRole("button", { name: "Test microphone" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Start camera preview" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Test speaker" })).toBeDisabled();
    expect(harness.getUserMedia).not.toHaveBeenCalled();
  });

  it("blocks device tests throughout Phone permission, dialing, and connected ownership", () => {
    setPhoneMediaBusy(true);
    render(<AudioVideoSettings />);
    expect(screen.getByRole("button", { name: "Test microphone" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Start camera preview" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Test speaker" })).toBeDisabled();
    expect(harness.getUserMedia).not.toHaveBeenCalled();
    expect(harness.play).not.toHaveBeenCalled();
    act(() => setPhoneMediaBusy(false));
    expect(screen.getByRole("button", { name: "Test microphone" })).toBeEnabled();
  });

  it("releases every active local test synchronously when Phone reserves media", async () => {
    const microphone = stream("audio");
    const camera = stream("video");
    harness.getUserMedia.mockResolvedValueOnce(microphone.value).mockResolvedValueOnce(camera.value);
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await screen.findByRole("option", { name: "Desk microphone" });
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await screen.findByText("Microphone is capturing for this local test.");
    await user.click(screen.getByRole("button", { name: "Start camera preview" }));
    await screen.findByLabelText("Local camera preview");
    await user.click(screen.getByRole("button", { name: "Test speaker" }));
    await waitFor(() => expect(harness.play).toHaveBeenCalledOnce());
    act(() => {
      setPhoneMediaBusy(true);
      // Capture is released before Phone can issue its own getUserMedia call.
      expect(microphone.track.stop).toHaveBeenCalledOnce();
      expect(camera.track.stop).toHaveBeenCalledOnce();
      expect(harness.pause).toHaveBeenCalled();
      expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:local-device-test");
    });
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
    expect(screen.getByText("Camera preview is off.")).toBeVisible();
  });

  it("discards late microphone and camera permission responses after Phone begins", async () => {
    let resolveMicrophone!: (value: unknown) => void;
    let resolveCamera!: (value: unknown) => void;
    harness.getUserMedia.mockImplementationOnce(() => new Promise((resolve) => { resolveMicrophone = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveCamera = resolve; }));
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await screen.findByRole("option", { name: "Desk microphone" });
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await user.click(screen.getByRole("button", { name: "Start camera preview" }));
    act(() => setPhoneMediaBusy(true));
    const microphone = stream("audio");
    const camera = stream("video");
    await act(async () => { resolveMicrophone(microphone.value); resolveCamera(camera.value); });
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(camera.track.stop).toHaveBeenCalledOnce();
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
    expect(screen.getByText("Camera preview is off.")).toBeVisible();
  });

});
