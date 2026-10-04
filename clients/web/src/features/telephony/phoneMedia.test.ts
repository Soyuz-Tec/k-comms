import { beforeEach, describe, expect, it, vi } from "vitest";
import { PhoneMedia } from "./phoneMedia";

const harness = vi.hoisted(() => ({
  events: new Map<string, (...args: unknown[]) => void>(), connect: vi.fn(), disconnect: vi.fn(), microphone: vi.fn(), startAudio: vi.fn(), stop: vi.fn(), options: vi.fn()
}));
vi.mock("livekit-client", () => ({
  Track: { Kind: { Audio: "audio" } },
  RoomEvent: { TrackSubscribed: "subscribed", TrackUnsubscribed: "unsubscribed", Reconnecting: "reconnecting", Reconnected: "reconnected", AudioPlaybackStatusChanged: "playback", Disconnected: "disconnected" },
  Room: class {
    constructor(options: unknown) { harness.options(options); }
    on(event: string, callback: (...args: unknown[]) => void) { harness.events.set(event, callback); }
    connect = harness.connect;
    disconnect = harness.disconnect;
    startAudio = harness.startAudio;
    canPlaybackAudio = true;
    localParticipant = { setMicrophoneEnabled: harness.microphone, trackPublications: new Map([["mic", { track: { stop: harness.stop } }]]) };
  }
}));
const credential = { server_url: "wss://media.example.test", participant_token: "token", expires_in: 60, ice_servers: [{ urls: ["turns:relay.example.test:443"], username: "ephemeral", credential: "ephemeral-secret" }] };

describe("phone media lifecycle", () => {
  beforeEach(() => { vi.clearAllMocks(); harness.events.clear(); harness.connect.mockResolvedValue(undefined); harness.microphone.mockResolvedValue(undefined); harness.startAudio.mockResolvedValue(undefined); });
  it("attaches only audio and releases tracks/elements on disconnect", async () => {
    const container = document.createElement("div");
    const state = vi.fn();
    const media = new PhoneMedia(credential, container, state, vi.fn());
    await media.connect(credential);
    expect(harness.microphone).toHaveBeenCalledWith(true);
    expect(harness.options).toHaveBeenCalledWith(expect.objectContaining({ rtcConfig: { iceServers: credential.ice_servers } }));
    const audio = document.createElement("audio");
    harness.events.get("subscribed")?.({ kind: "audio", attach: () => audio });
    const videoAttach = vi.fn();
    harness.events.get("subscribed")?.({ kind: "video", attach: videoAttach });
    expect(container.querySelector("audio")).toBe(audio);
    expect(videoAttach).not.toHaveBeenCalled();
    media.disconnect();
    expect(harness.stop).toHaveBeenCalled();
    expect(container.childElementCount).toBe(0);
    expect(harness.disconnect).toHaveBeenCalled();
  });
  it("never opens microphone after a cancelled connection resolves", async () => {
    let resolve: () => void = () => undefined;
    harness.connect.mockImplementation(() => new Promise<void>((done) => { resolve = done; }));
    const media = new PhoneMedia(credential, document.createElement("div"), vi.fn(), vi.fn());
    const pending = media.connect(credential);
    media.disconnect();
    resolve();
    await pending;
    expect(harness.microphone).not.toHaveBeenCalled();
    expect(harness.stop).toHaveBeenCalled();
  });
  it("reports autoplay blocking and offers explicit playback retry", async () => {
    harness.startAudio.mockRejectedValueOnce(new Error("Autoplay blocked"));
    const blocked = vi.fn();
    const media = new PhoneMedia(credential, document.createElement("div"), vi.fn(), blocked);
    await media.connect(credential);
    expect(blocked).toHaveBeenLastCalledWith(true);
    await media.startPlayback();
    expect(blocked).toHaveBeenLastCalledWith(false);
    media.disconnect();
  });
});
