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
  resume: vi.fn(),
  analyser: vi.fn(),
  source: vi.fn(),
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
  const track = { stop: vi.fn(), getSettings: () => ({ deviceId: kind === "audio" ? "mic-1" : "camera-1" }), readyState: "live" as "live" | "ended", onended: null as (() => void) | null };
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
    harness.resume.mockReset().mockResolvedValue(undefined);
    harness.analyser.mockReset().mockImplementation(() => ({ fftSize: 256, getByteTimeDomainData: (array: Uint8Array) => array.fill(128) }));
    harness.source.mockReset().mockImplementation(() => ({ connect: vi.fn() }));
    harness.sink.mockResolvedValue(undefined);
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia: harness.getUserMedia } });
    vi.stubGlobal("AudioContext", class {
      close = harness.close;
      resume = harness.resume;
      createAnalyser = harness.analyser;
      createMediaStreamSource = harness.source;
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
    const cancelFrame = vi.spyOn(window, "cancelAnimationFrame");
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
    expect(cancelFrame).toHaveBeenCalledOnce();
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

  it("releases capture once if creating its audio context fails", async () => {
    const microphone = stream("audio");
    harness.getUserMedia.mockResolvedValue(microphone.value);
    vi.stubGlobal("AudioContext", class { constructor() { throw new Error("Audio context unavailable"); } });
    const user = userEvent.setup();
    const view = render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Audio context unavailable");
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).not.toHaveBeenCalled();
    view.unmount();
    expect(microphone.track.stop).toHaveBeenCalledOnce();
  });

  it.each(["analyser", "source"] as const)("releases its stream and context once after %s setup fails", async (stage) => {
    const microphone = stream("audio");
    harness.getUserMedia.mockResolvedValue(microphone.value);
    harness[stage].mockImplementation(() => { throw new Error("Microphone setup failed"); });
    const user = userEvent.setup();
    const view = render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Microphone setup failed");
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
    expect(screen.getByRole("button", { name: "Test microphone" })).toBeEnabled();
    view.unmount();
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
  });

  it("releases its stream and context once when audio resume fails", async () => {
    const microphone = stream("audio");
    harness.getUserMedia.mockResolvedValue(microphone.value);
    harness.resume.mockRejectedValueOnce(new Error("Audio resume failed"));
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Audio resume failed");
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
  });

  it.each(["section closes", "Phone reserves media"] as const)("does not release capture twice when resume rejects after %s", async (cancellation) => {
    const microphone = stream("audio");
    harness.getUserMedia.mockResolvedValue(microphone.value);
    let rejectResume!: (reason: Error) => void;
    harness.resume.mockImplementationOnce(() => new Promise<void>((_, reject) => { rejectResume = reject; }));
    const user = userEvent.setup();
    const view = render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await waitFor(() => expect(harness.resume).toHaveBeenCalledOnce());
    if (cancellation === "section closes") view.unmount();
    else act(() => setPhoneMediaBusy(true));
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
    await act(async () => rejectResume(new Error("Cancelled resume failed")));
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
    if (cancellation === "Phone reserves media") expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("keeps a replacement microphone test running when an older resume rejects", async () => {
    const previous = stream("audio");
    const replacement = stream("audio");
    harness.getUserMedia.mockResolvedValueOnce(previous.value).mockResolvedValueOnce(replacement.value);
    let rejectPrevious!: (reason: Error) => void;
    harness.resume.mockImplementationOnce(() => new Promise<void>((_, reject) => { rejectPrevious = reject; }));
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await waitFor(() => expect(harness.resume).toHaveBeenCalledOnce());
    await user.click(screen.getByRole("button", { name: "Stop microphone test" }));
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await screen.findByText("Microphone is capturing for this local test.");
    await act(async () => rejectPrevious(new Error("Previous resume failed")));
    expect(previous.track.stop).toHaveBeenCalledOnce();
    expect(replacement.track.stop).not.toHaveBeenCalled();
    expect(harness.close).toHaveBeenCalledOnce();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByText("Microphone is capturing for this local test.")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Stop microphone test" }));
    expect(replacement.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledTimes(2);
  });

  it("ignores an old track-ended callback after another microphone test begins", async () => {
    const previous = stream("audio");
    const replacement = stream("audio");
    harness.getUserMedia.mockResolvedValueOnce(previous.value).mockResolvedValueOnce(replacement.value);
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await screen.findByText("Microphone is capturing for this local test.");
    const previousEnded = previous.track.onended;
    expect(previousEnded).not.toBeNull();
    await user.click(screen.getByRole("button", { name: "Stop microphone test" }));
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await screen.findByText("Microphone is capturing for this local test.");
    act(() => previousEnded?.());
    expect(previous.track.stop).toHaveBeenCalledOnce();
    expect(replacement.track.stop).not.toHaveBeenCalled();
    expect(harness.close).toHaveBeenCalledOnce();
    expect(screen.getByText("Microphone is capturing for this local test.")).toBeVisible();
  });

  it.each(["resolves", "rejects"] as const)("releases a track that ends before audio resume %s without claiming capture", async (settlement) => {
    const microphone = stream("audio");
    harness.getUserMedia.mockResolvedValue(microphone.value);
    let resolveResume!: () => void;
    let rejectResume!: (reason: Error) => void;
    harness.resume.mockImplementationOnce(() => new Promise<void>((resolve, reject) => {
      resolveResume = resolve;
      rejectResume = reject;
    }));
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await waitFor(() => expect(harness.resume).toHaveBeenCalledOnce());
    act(() => {
      microphone.track.readyState = "ended";
      microphone.track.onended?.();
    });
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
    await act(async () => {
      if (settlement === "resolves") resolveResume();
      else rejectResume(new Error("Ended microphone resume failed"));
    });
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByText("Microphone is not capturing.")).toBeVisible();
    expect(screen.getByRole("button", { name: "Test microphone" })).toBeEnabled();
  });

  it("does not activate an ended track when no ended event was dispatched before resume completes", async () => {
    const microphone = stream("audio");
    harness.getUserMedia.mockResolvedValue(microphone.value);
    let resolveResume!: () => void;
    harness.resume.mockImplementationOnce(() => new Promise<void>((resolve) => { resolveResume = resolve; }));
    const user = userEvent.setup();
    render(<AudioVideoSettings />);
    await user.click(screen.getByRole("button", { name: "Test microphone" }));
    await waitFor(() => expect(harness.resume).toHaveBeenCalledOnce());
    microphone.track.readyState = "ended";
    await act(async () => resolveResume());
    expect(microphone.track.stop).toHaveBeenCalledOnce();
    expect(harness.close).toHaveBeenCalledOnce();
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
