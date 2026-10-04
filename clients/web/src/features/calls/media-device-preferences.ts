type DeviceKind = "microphone" | "camera" | "speaker";

const KEY = "k-comms.media-device-preferences.v1";

export function readMediaDevicePreference(kind: DeviceKind): string {
  try {
    const stored: unknown = JSON.parse(window.localStorage.getItem(KEY) || "{}");
    if (!stored || typeof stored !== "object") return "";
    const value = (stored as Partial<Record<DeviceKind, unknown>>)[kind];
    return typeof value === "string" && value.length <= 1024 ? value : "";
  } catch {
    return "";
  }
}

export function saveMediaDevicePreference(kind: DeviceKind, deviceId: string) {
  try {
    window.localStorage.setItem(KEY, JSON.stringify({
      microphone: readMediaDevicePreference("microphone"),
      camera: readMediaDevicePreference("camera"),
      speaker: readMediaDevicePreference("speaker"),
      [kind]: deviceId
    }));
  } catch {
    // Restricted storage must not prevent device selection or testing.
  }
}
