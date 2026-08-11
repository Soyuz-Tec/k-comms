import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Call, Conversation } from "../../types";
import { CallPanel } from "./CallPanel";

const livekit = vi.hoisted(() => ({
  events: {
    ParticipantConnected: "participantConnected",
    ParticipantDisconnected: "participantDisconnected",
    TrackPublished: "trackPublished",
    TrackUnpublished: "trackUnpublished",
    LocalTrackPublished: "localTrackPublished",
    LocalTrackUnpublished: "localTrackUnpublished",
    TrackMuted: "trackMuted",
    TrackUnmuted: "trackUnmuted",
    ActiveSpeakersChanged: "activeSpeakersChanged",
    TrackSubscribed: "trackSubscribed",
    TrackUnsubscribed: "trackUnsubscribed",
    Reconnecting: "reconnecting",
    Reconnected: "reconnected",
    ConnectionStateChanged: "connectionStateChanged",
    AudioPlaybackStatusChanged: "audioPlaybackChanged",
    VideoPlaybackStatusChanged: "videoPlaybackChanged",
    MediaDevicesChanged: "mediaDevicesChanged",
    MediaDevicesError: "mediaDevicesError",
    Disconnected: "disconnected"
  },
  callbacks: new Map<string, (...args: unknown[]) => void>(),
  remoteParticipants: new Map<string, Record<string, unknown>>(),
  localParticipant: {
    sid: "local-sid",
    identity: "user-1",
    name: "Ada",
    isLocal: true,
    isMicrophoneEnabled: false,
    isCameraEnabled: false,
    isScreenShareEnabled: false,
    isSpeaking: false,
    trackPublications: new Map<string, { track?: { stop: () => void } }>(),
    videoTrackPublications: new Map(),
    setMicrophoneEnabled: vi.fn(),
    setCameraEnabled: vi.fn(),
    setScreenShareEnabled: vi.fn()
  },
  getLocalDevices: vi.fn(),
  connect: vi.fn(),
  disconnect: vi.fn(),
  startAudio: vi.fn(),
  startVideo: vi.fn(),
  switchActiveDevice: vi.fn(),
  canPlaybackAudio: true,
  canPlaybackVideo: true,
  supportsVP9: true,
  checkWebsocket: vi.fn(),
  checkTURN: vi.fn(),
  checkPublishAudio: vi.fn(),
  checkReconnect: vi.fn(),
  simulateScenario: vi.fn(),
  connectionCheckOptions: [] as Record<string, unknown>[],
  roomOptions: [] as Record<string, unknown>[]
}));

vi.mock("livekit-client", () => ({
  CheckStatus: { SUCCESS: "success", FAILED: "failed", SKIPPED: "skipped", RUNNING: "running" },
  ConnectionCheck: class MockConnectionCheck {
    constructor(_serverUrl: string, _participantToken: string, options: Record<string, unknown>) {
      livekit.connectionCheckOptions.push(options);
    }
    checkWebsocket() { return livekit.checkWebsocket(); }
    checkTURN() { return livekit.checkTURN(); }
    checkPublishAudio() { return livekit.checkPublishAudio(); }
    checkReconnect() { return livekit.checkReconnect(); }
  },
  ConnectionState: { Reconnecting: "reconnecting", SignalReconnecting: "signalReconnecting" },
  DisconnectReason: { PARTICIPANT_REMOVED: 4, ROOM_DELETED: 5 },
  RoomEvent: livekit.events,
  ScreenSharePresets: {
    h1080fps15: { encoding: { maxBitrate: 2_500_000, maxFramerate: 15, priority: "medium" } }
  },
  supportsVP9: () => livekit.supportsVP9,
  Track: {
    Kind: { Audio: "audio", Video: "video" },
    Source: { Camera: "camera", Microphone: "microphone", ScreenShare: "screen_share" }
  },
  Room: class MockRoom {
    static getLocalDevices(kind: MediaDeviceKind, requestPermissions?: boolean) {
      return livekit.getLocalDevices(kind, requestPermissions);
    }
    constructor(options: Record<string, unknown>) {
      livekit.roomOptions.push(options);
    }
    remoteParticipants = livekit.remoteParticipants;
    localParticipant = livekit.localParticipant;
    get canPlaybackAudio() { return livekit.canPlaybackAudio; }
    get canPlaybackVideo() { return livekit.canPlaybackVideo; }
    on(event: string, callback: (...args: unknown[]) => void) {
      livekit.callbacks.set(event, callback);
      return this;
    }
    off(event: string) {
      livekit.callbacks.delete(event);
      return this;
    }
    simulateScenario(scenario: string) { return livekit.simulateScenario(scenario); }
    connect(url: string, token: string, options: unknown) { return livekit.connect(url, token, options); }
    disconnect(stopTracks?: boolean) { return livekit.disconnect(stopTracks); }
    startAudio() { return livekit.startAudio(); }
    startVideo() { return livekit.startVideo(); }
    switchActiveDevice(kind: MediaDeviceKind, deviceId: string, exact?: boolean) {
      return livekit.switchActiveDevice(kind, deviceId, exact);
    }
  }
}));

const conversation: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "group",
  title: "Design group",
  counterpart_user_id: null,
  counterpart_display_name: null,
  visibility: "private",
  latest_sequence: 0,
  inserted_at: "2026-07-15T10:00:00Z",
  updated_at: "2026-07-15T10:00:00Z"
};

const activeVideoCall: Call = {
  id: "call-1",
  conversation_id: conversation.id,
  started_by_user_id: "user-1",
  media_kind: "video",
  status: "active",
  started_at: "2026-07-15T10:00:00Z",
  expires_at: "2026-07-15T18:00:00Z",
  can_end: true
};

const activeAudioCall: Call = {
  ...activeVideoCall,
  id: "audio-call-1",
  media_kind: "audio"
};

const secondConversation: Conversation = {
  ...conversation,
  id: "conversation-2",
  title: "Operations group"
};

function device(kind: MediaDeviceKind, deviceId: string, label: string): MediaDeviceInfo {
  return { kind, deviceId, label, groupId: "group-1", toJSON: () => ({}) };
}

function apiWith(active: Call | null) {
  const responseCall = active || activeVideoCall;
  const joined = {
    data: responseCall,
    credential: {
      server_url: "wss://media.example.test",
      participant_token: "memory-only-call-token",
      expires_in: 300
    }
  };
  return {
    call: vi.fn().mockResolvedValue(active),
    startCall: vi.fn().mockResolvedValue(joined),
    joinCall: vi.fn().mockResolvedValue(joined),
    endCall: vi.fn().mockResolvedValue({ ...responseCall, status: "ended" })
  } as unknown as ApiClient;
}

function previewStream(id: string) {
  const stop = vi.fn();
  const track = {
    stop,
    getSettings: () => ({ deviceId: id })
  } as unknown as MediaStreamTrack;
  const stream = {
    getTracks: () => [track],
    getVideoTracks: () => [track]
  } as unknown as MediaStream;
  return { stop, stream };
}

function remoteParticipant(
  id: string,
  name: string,
  options: { speaking?: boolean; screenSharing?: boolean } = {}
) {
  const element = document.createElement("video");
  const track = {
    sid: `${id}-camera-track`,
    kind: "video",
    attach: vi.fn(() => element),
    detach: vi.fn(() => [element])
  };
  return {
    participant: {
      sid: `${id}-sid`,
      identity: id,
      name,
      isLocal: false,
      isMicrophoneEnabled: true,
      isCameraEnabled: true,
      isScreenShareEnabled: options.screenSharing ?? false,
      isSpeaking: options.speaking ?? false,
      audioTrackPublications: new Map(),
      videoTrackPublications: new Map([
        ["camera", { trackSid: `${id}-camera-publication`, source: "camera", videoTrack: track }]
      ])
    },
    element,
    track
  };
}

describe("CallPanel calls", () => {
  beforeEach(() => {
    window.localStorage.clear();
    livekit.callbacks.clear();
    livekit.remoteParticipants.clear();
    livekit.connectionCheckOptions.length = 0;
    livekit.roomOptions.length = 0;
    const passed = { status: "success" };
    livekit.checkWebsocket.mockReset().mockResolvedValue(passed);
    livekit.checkTURN.mockReset().mockResolvedValue(passed);
    livekit.checkPublishAudio.mockReset().mockResolvedValue(passed);
    livekit.checkReconnect.mockReset().mockResolvedValue(passed);
    livekit.simulateScenario.mockReset().mockResolvedValue(undefined);
    livekit.supportsVP9 = true;
    livekit.localParticipant.isMicrophoneEnabled = false;
    livekit.localParticipant.isCameraEnabled = false;
    livekit.localParticipant.isScreenShareEnabled = false;
    livekit.localParticipant.trackPublications.clear();
    livekit.localParticipant.videoTrackPublications.clear();
    livekit.getLocalDevices.mockReset().mockImplementation(async (kind: MediaDeviceKind) => (
      kind === "videoinput"
        ? [device("videoinput", "camera-1", "Built-in camera"), device("videoinput", "camera-2", "USB camera")]
        : [device("audioinput", "mic-1", "Built-in microphone"), device("audioinput", "mic-2", "USB microphone")]
    ));
    livekit.connect.mockReset().mockResolvedValue(undefined);
    livekit.disconnect.mockReset().mockResolvedValue(undefined);
    livekit.startAudio.mockReset().mockResolvedValue(undefined);
    livekit.startVideo.mockReset().mockResolvedValue(undefined);
    livekit.switchActiveDevice.mockReset().mockResolvedValue(true);
    livekit.localParticipant.setMicrophoneEnabled.mockReset().mockImplementation(async (enabled: boolean) => {
      livekit.localParticipant.isMicrophoneEnabled = enabled;
    });
    livekit.localParticipant.setCameraEnabled.mockReset().mockImplementation(async (enabled: boolean) => {
      livekit.localParticipant.isCameraEnabled = enabled;
    });
    livekit.localParticipant.setScreenShareEnabled.mockReset().mockImplementation(async (enabled: boolean) => {
      livekit.localParticipant.isScreenShareEnabled = enabled;
    });
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue({
        matches: false,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn()
      })
    });
  });

  it("offers distinct actions and stops every preview track on camera switch and cancel", async () => {
    const first = previewStream("camera-1");
    const second = previewStream("camera-2");
    const getUserMedia = vi.fn()
      .mockResolvedValueOnce(first.stream)
      .mockResolvedValueOnce(second.stream);
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia } });
    const user = userEvent.setup();
    render(<CallPanel api={apiWith(null)} conversation={conversation} audioEnabled videoEnabled currentUserDisplayName="Ada" />);

    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Start video call" }));
    const dialog = screen.getByRole("dialog", { name: "Start a video call" });
    await user.click(within(dialog).getByRole("checkbox", { name: "Use camera when I join" }));
    await waitFor(() => expect(getUserMedia).toHaveBeenCalledTimes(1));
    expect(within(dialog).getByLabelText("Camera preview")).toBeVisible();

    await user.selectOptions(within(dialog).getByRole("combobox", { name: /Camera/ }), "camera-2");
    await waitFor(() => expect(getUserMedia).toHaveBeenCalledTimes(2));
    expect(first.stop).toHaveBeenCalledTimes(1);

    await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
    expect(second.stop).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("publishes selected devices, renders a three-person video grid, controls screen share, and detaches tracks", async () => {
    const preview = previewStream("camera-2");
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia: vi.fn().mockResolvedValue(preview.stream) } });
    const api = apiWith(null);
    const user = userEvent.setup();
    const view = render(<CallPanel api={api} conversation={conversation} audioEnabled videoEnabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Start video call" }));
    const dialog = screen.getByRole("dialog", { name: "Start a video call" });
    await user.click(within(dialog).getByRole("checkbox", { name: "Use microphone when I join" }));
    await user.selectOptions(within(dialog).getByRole("combobox", { name: /Microphone/ }), "mic-2");
    await user.selectOptions(within(dialog).getByRole("combobox", { name: /Camera/ }), "camera-2");
    await user.click(within(dialog).getByRole("checkbox", { name: "Use camera when I join" }));
    await waitFor(() => expect(within(dialog).getByLabelText("Camera preview")).toBeVisible());
    await user.click(within(dialog).getByRole("button", { name: "Join video call" }));

    expect(await screen.findByText("Connected")).toBeVisible();
    expect(screen.getByRole("status", { name: "Local capture status" })).toHaveTextContent(
      "Microphone on"
    );
    expect(screen.getByRole("status", { name: "Local capture status" })).toHaveTextContent(
      "Camera on"
    );
    expect(api.startCall).toHaveBeenCalledWith(conversation.id, "video");
    expect(livekit.localParticipant.setMicrophoneEnabled).toHaveBeenCalledWith(true, expect.objectContaining({ deviceId: "mic-2" }));
    expect(livekit.localParticipant.setCameraEnabled).toHaveBeenCalledWith(true, expect.objectContaining({ deviceId: "camera-2" }));
    expect(preview.stop).toHaveBeenCalledTimes(1);

    livekit.switchActiveDevice.mockResolvedValueOnce(false);
    await user.selectOptions(screen.getByRole("combobox", { name: "Camera" }), "camera-1");
    await waitFor(() => expect(screen.getByRole<HTMLSelectElement>("combobox", { name: "Camera" }).value).toBe("camera-2"));
    expect(livekit.switchActiveDevice).toHaveBeenCalledWith("videoinput", "camera-1", true);

    livekit.switchActiveDevice.mockRejectedValueOnce(new Error("microphone switch failed"));
    await user.selectOptions(screen.getByRole("combobox", { name: "Microphone" }), "mic-1");
    await waitFor(() => expect(screen.getByRole<HTMLSelectElement>("combobox", { name: "Microphone" }).value).toBe("mic-2"));
    expect(livekit.switchActiveDevice).toHaveBeenCalledWith("audioinput", "mic-1", true);

    const grace = remoteParticipant("user-2", "Grace");
    const linus = remoteParticipant("user-3", "Linus");
    livekit.remoteParticipants.set("user-2", grace.participant);
    livekit.remoteParticipants.set("user-3", linus.participant);
    act(() => livekit.callbacks.get(livekit.events.ParticipantConnected)?.());

    const grid = screen.getByRole("list", { name: "Video participants" });
    expect(await within(grid).findAllByRole("listitem")).toHaveLength(3);
    expect(document.querySelectorAll('video[data-k-comms-call-video="remote"]')).toHaveLength(2);

    await user.click(screen.getByRole("button", { name: "Share screen" }));
    expect(livekit.localParticipant.setScreenShareEnabled).toHaveBeenCalledWith(true, expect.objectContaining({ audio: false, video: true }));
    expect(await screen.findByRole("button", { name: "Stop sharing screen" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Turn camera off" }));
    expect(livekit.localParticipant.setCameraEnabled).toHaveBeenLastCalledWith(false);

    view.unmount();
    expect(livekit.disconnect).toHaveBeenCalledWith(true);
    expect(grace.track.detach).toHaveBeenCalled();
    expect(linus.track.detach).toHaveBeenCalled();
  });

  it("publishes VP9 with a VP8 backup and a bandwidth-bounded screen share", async () => {
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeAudioCall)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
      />
    );

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Join the audio call" }))
        .getByRole("button", { name: "Join muted" })
    );
    expect(await screen.findByText("Connected")).toBeVisible();

    expect(livekit.roomOptions.at(-1)?.publishDefaults).toEqual({
      videoCodec: "vp9",
      backupCodec: true,
      dtx: true,
      red: true,
      screenShareEncoding: { maxBitrate: 2_500_000, maxFramerate: 15, priority: "medium" }
    });
  });

  it("publishes VP8 when the browser cannot encode VP9", async () => {
    livekit.supportsVP9 = false;
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeAudioCall)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
      />
    );

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Join the audio call" }))
        .getByRole("button", { name: "Join muted" })
    );
    expect(await screen.findByText("Connected")).toBeVisible();

    expect(livekit.roomOptions.at(-1)?.publishDefaults).toMatchObject({ videoCodec: "vp8" });
  });

  it("supplies the server-issued relay to the media session", async () => {
    const api = apiWith(activeAudioCall);
    (api.joinCall as ReturnType<typeof vi.fn>).mockResolvedValue({
      data: activeAudioCall,
      credential: {
        server_url: "wss://media.example.test",
        participant_token: "memory-only-call-token",
        expires_in: 300,
        ice_servers: [
          { urls: ["stun:stun.example.test:3478"] },
          {
            urls: ["turns:relay.example.test:5349"],
            username: "1900000000:user-1",
            credential: "derived-relay-credential"
          }
        ]
      }
    });
    const user = userEvent.setup();
    render(
      <CallPanel
        api={api}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
      />
    );

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Join the audio call" }))
        .getByRole("button", { name: "Join muted" })
    );
    expect(await screen.findByText("Connected")).toBeVisible();

    expect(livekit.roomOptions.at(-1)?.rtcConfig).toEqual({
      iceServers: [
        { urls: ["stun:stun.example.test:3478"] },
        {
          urls: ["turns:relay.example.test:5349"],
          username: "1900000000:user-1",
          credential: "derived-relay-credential"
        }
      ]
    });
  });

  it("leaves the SDK defaults alone when the server issues no relay", async () => {
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeAudioCall)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
      />
    );

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Join the audio call" }))
        .getByRole("button", { name: "Join muted" })
    );
    expect(await screen.findByText("Connected")).toBeVisible();

    expect(livekit.roomOptions.at(-1)).not.toHaveProperty("rtcConfig");
  });

  it("runs the office preflight and forces relay for a readiness launch", async () => {
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeAudioCall)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
        launchRequest="audio"
        launchRequestId={42}
        launchReadinessMode="office"
      />
    );

    const dialog = await screen.findByRole("dialog", { name: "Join the audio call" });
    expect(within(dialog).getByRole("checkbox", { name: /Run secure office network qualification/ })).toBeChecked();
    expect(within(dialog).getByRole("checkbox", { name: "Use microphone when I join" })).toBeDisabled();
    expect(within(dialog).queryByRole("button", { name: "Join muted" })).not.toBeInTheDocument();

    await user.click(within(dialog).getByRole("button", { name: "Run office call test" }));
    expect(await screen.findByText("Connected")).toBeVisible();

    expect(livekit.checkWebsocket).toHaveBeenCalledOnce();
    expect(livekit.checkTURN).toHaveBeenCalledOnce();
    expect(livekit.checkPublishAudio).toHaveBeenCalledOnce();
    expect(livekit.checkReconnect).toHaveBeenCalledOnce();
    expect(livekit.connectionCheckOptions.at(-1)).toEqual({
      connectOptions: { rtcConfig: { iceTransportPolicy: "relay" } }
    });
    expect(livekit.roomOptions.at(-1)?.rtcConfig).toEqual({ iceTransportPolicy: "relay" });
    expect(livekit.simulateScenario).toHaveBeenCalledWith("force-tls");
  });

  it("keeps a failed readiness run in the lobby with an exportable report", async () => {
    livekit.connect.mockRejectedValueOnce(new Error("relay unavailable"));
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeAudioCall)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
        launchRequest="audio"
        launchRequestId={43}
        launchReadinessMode="office"
      />
    );

    const dialog = await screen.findByRole("dialog", { name: "Join the audio call" });
    await user.click(within(dialog).getByRole("button", { name: "Run office call test" }));

    expect(await within(dialog).findByText("Office network qualification did not complete."))
      .toBeVisible();
    expect(within(dialog).getByRole("button", { name: "Download privacy-safe report" }))
      .toBeVisible();
    expect(within(dialog).getByRole("button", { name: "Run office call test" }))
      .toBeEnabled();
  });

  it("offers direct audio only in one-to-one audio prejoin with explicit privacy consent", async () => {
    const directConversation: Conversation = {
      ...conversation,
      id: "direct-conversation-1",
      kind: "direct",
      title: "Grace Hopper",
      counterpart_user_id: "user-2",
      counterpart_display_name: "Grace Hopper"
    };
    const user = userEvent.setup();
    const view = render(
      <CallPanel
        api={apiWith(null)}
        conversation={directConversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
        currentUserId="user-1"
      />
    );

    await user.click(await screen.findByRole("button", { name: "Start audio call" }));
    const directCheckbox = within(screen.getByRole("dialog", { name: "Start an audio call" }))
      .getByRole("checkbox", { name: /Prefer a direct connection/ });
    expect(directCheckbox).not.toBeChecked();
    expect(screen.getByText(/reveals each device's network address/i)).toBeVisible();
    await user.click(directCheckbox);
    expect(directCheckbox).toBeChecked();

    view.rerender(
      <CallPanel
        api={apiWith(null)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
        currentUserId="user-1"
      />
    );
    await user.click(await screen.findByRole("button", { name: "Start audio call" }));
    expect(screen.queryByRole("checkbox", { name: /Prefer a direct connection/ }))
      .not.toBeInTheDocument();
  });

  it("ignores old-room device and media failures after switching conversations", async () => {
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn() }
    });
    const api = apiWith(activeVideoCall);
    vi.mocked(api.call).mockImplementation(async (conversationId) =>
      conversationId === conversation.id ? activeVideoCall : null
    );
    const user = userEvent.setup();
    const view = render(
      <CallPanel
        api={api}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
      />
    );

    await user.click(await screen.findByRole("button", { name: "Join video call" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Join the video call" }))
        .getByRole("button", { name: "Join video call" })
    );
    expect(await screen.findByText("Connected")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Unmute microphone" }));
    expect(
      await screen.findByRole("button", { name: "Mute microphone" })
    ).toBeVisible();

    const deviceSwitch = deferred<boolean>();
    const screenShare = deferred<void>();
    livekit.switchActiveDevice.mockImplementationOnce(() => deviceSwitch.promise);
    livekit.localParticipant.setScreenShareEnabled.mockImplementationOnce(
      () => screenShare.promise
    );

    await user.selectOptions(
      screen.getByRole("combobox", { name: "Microphone" }),
      "mic-2"
    );
    await waitFor(() =>
      expect(livekit.switchActiveDevice).toHaveBeenCalledWith(
        "audioinput",
        "mic-2",
        true
      )
    );
    await user.click(screen.getByRole("button", { name: "Share screen" }));
    await waitFor(() =>
      expect(livekit.localParticipant.setScreenShareEnabled)
        .toHaveBeenCalledWith(true, expect.any(Object))
    );

    view.rerender(
      <CallPanel
        api={api}
        conversation={secondConversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
      />
    );
    await user.click(
      await screen.findByRole("button", { name: "Start video call" })
    );
    const secondDialog = screen.getByRole("dialog", {
      name: "Start a video call"
    });
    const secondMicrophone = within(secondDialog).getByRole<HTMLSelectElement>(
      "combobox",
      { name: /Microphone/ }
    );
    await waitFor(() => expect(secondMicrophone.value).toBe("mic-2"));

    await act(async () => {
      deviceSwitch.reject(new Error("old microphone switch failed"));
      screenShare.reject(new Error("old screen share failed"));
    });

    expect(secondMicrophone.value).toBe("mic-2");
    expect(screen.queryByText(/old microphone switch failed/i))
      .not.toBeInTheDocument();
    expect(screen.queryByText(/old screen share failed/i))
      .not.toBeInTheDocument();
    expect(secondDialog).toBeVisible();
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}
