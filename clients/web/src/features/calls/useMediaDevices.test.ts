import { act, renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { saveMediaDevicePreference } from "./media-device-preferences";
import { useMediaDevices } from "./useMediaDevices";

const device = (kind: MediaDeviceKind, id: string) => ({ kind, deviceId: id, label: id, groupId: "", toJSON: () => ({}) } as MediaDeviceInfo);
vi.mock("livekit-client", () => ({ Room: { getLocalDevices: (kind: MediaDeviceKind) => Promise.resolve([device(kind, `${kind}-1`), device(kind, `${kind}-2`)]) } }));

function settingsHook() {
  const mountedRef = { current: true };
  return renderHook(() => useMediaDevices({ mountedRef, setError: vi.fn() }));
}

describe("persistent call device preferences", () => {
  beforeEach(() => window.localStorage.clear());

  it("applies changed preferences when the same mounted call opens its next lobby", async () => {
    const view = settingsHook();
    await act(async () => view.result.current.loadPrejoinDevices("video", () => true));
    expect(view.result.current.selectedMicrophone).toBe("audioinput-1");
    saveMediaDevicePreference("microphone", "audioinput-2");
    saveMediaDevicePreference("speaker", "audiooutput-2");
    saveMediaDevicePreference("camera", "videoinput-2");
    await act(async () => view.result.current.loadPrejoinDevices("video", () => true));
    expect(view.result.current.selectedMicrophone).toBe("audioinput-2");
    expect(view.result.current.selectedSpeaker).toBe("audiooutput-2");
    expect(view.result.current.selectedCamera).toBe("videoinput-2");
    act(() => view.result.current.setSelectedMicrophone("audioinput-1"));
    await act(async () => view.result.current.loadPrejoinDevices("video", () => true));
    expect(view.result.current.selectedMicrophone).toBe("audioinput-1");
  });

  it("leaves active device selection unchanged when the caller rejects a refresh", async () => {
    const view = settingsHook();
    await act(async () => view.result.current.loadPrejoinDevices("video", () => true));
    saveMediaDevicePreference("microphone", "audioinput-2");
    await act(async () => view.result.current.loadPrejoinDevices("video", () => false));
    expect(view.result.current.selectedMicrophone).toBe("audioinput-1");
    await act(async () => view.result.current.loadPrejoinDevices("video", () => true));
    expect(view.result.current.selectedMicrophone).toBe("audioinput-2");
  });

  it("preserves camera preference across an audio-only lobby and applies later changes", async () => {
    saveMediaDevicePreference("camera", "videoinput-2");
    const view = settingsHook();
    await act(async () => view.result.current.loadPrejoinDevices("audio", () => true));
    expect(view.result.current.selectedCamera).toBe("videoinput-2");
    saveMediaDevicePreference("camera", "videoinput-1");
    await act(async () => view.result.current.loadPrejoinDevices("audio", () => true));
    expect(view.result.current.selectedCamera).toBe("videoinput-2");
    await act(async () => view.result.current.loadPrejoinDevices("video", () => true));
    expect(view.result.current.selectedCamera).toBe("videoinput-1");
  });
});
