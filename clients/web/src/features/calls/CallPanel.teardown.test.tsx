import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Call, Conversation } from "../../types";
import { CallPanel } from "./CallPanel";
import { requestCallSessionTeardown } from "./callSessionEvents";

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
  roomOptions: [] as Record<string, unknown>[]
}));

vi.mock("livekit-client", () => ({
  ConnectionState: { Reconnecting: "reconnecting", SignalReconnecting: "signalReconnecting" },
  DisconnectReason: { PARTICIPANT_REMOVED: 4, ROOM_DELETED: 5 },
  RoomEvent: livekit.events,
  ScreenSharePresets: {
    h1080fps15: { encoding: { maxBitrate: 2_500_000, maxFramerate: 15, priority: "medium" } }
  },
  supportsVP9: () => livekit.supportsVP9,
  Track: {
    Kind: { Audio: "audio", Video: "video" },
    Source: { Camera: "camera", ScreenShare: "screen_share" }
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

describe("CallPanel calls", () => {
  beforeEach(() => {
    window.localStorage.clear();
    livekit.callbacks.clear();
    livekit.remoteParticipants.clear();
    livekit.roomOptions.length = 0;
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

  it("focuses the connected dock and keeps collaboration routes one action away", async () => {
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn() }
    });
    const onNavigate = vi.fn();
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeVideoCall)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
        onNavigate={onNavigate}
      />
    );

    await user.click(await screen.findByRole("button", { name: "Join video call" }));
    const dialog = screen.getByRole("dialog", { name: "Join the video call" });
    await user.click(within(dialog).getByRole("button", { name: "Join video call" }));

    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    expect(activeCall).toHaveAttribute("aria-modal", "true");
    const minimize = within(activeCall).getByRole("button", { name: "Minimize" });
    await waitFor(() => expect(minimize).toHaveFocus());
    expect(screen.getByRole("navigation", { name: "Call workspace" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Directory" }));

    expect(onNavigate).toHaveBeenCalledWith("/app/directory");
    expect(screen.getByRole("button", { name: "Show call" })).toHaveAttribute(
      "aria-expanded",
      "false"
    );
  });

  it("returns instant-room guests to chat and omits unsupported files", async () => {
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn() }
    });
    const onOpenChat = vi.fn();
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeVideoCall)}
        conversation={conversation}
        audioEnabled
        videoEnabled
        currentUserDisplayName="Ada"
        onOpenChat={onOpenChat}
      />
    );

    await user.click(await screen.findByRole("button", { name: "Join video call" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Join the video call" }))
        .getByRole("button", { name: "Join video call" })
    );

    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    expect(within(activeCall).queryByRole("button", { name: "Files" }))
      .not.toBeInTheDocument();
    await user.click(
      within(activeCall).getByRole("button", { name: "Open room chat" })
    );

    expect(onOpenChat).toHaveBeenCalledTimes(1);
    expect(await screen.findByRole("region", { name: "Design group" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Show call" })).toHaveAttribute(
      "aria-expanded",
      "false"
    );
  });

  it("isolates the covered mobile workspace until an expanded call is minimized", async () => {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue({
        matches: true,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn()
      })
    });
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn() }
    });
    const user = userEvent.setup();
    render(
      <>
        <button type="button">Background action</button>
        <CallPanel
          api={apiWith(activeVideoCall)}
          conversation={conversation}
          audioEnabled
          videoEnabled
          currentUserDisplayName="Ada"
        />
      </>
    );

    const backgroundAction = screen.getByRole("button", { name: "Background action" });
    await user.click(await screen.findByRole("button", { name: "Join video call" }));
    await user.click(
      within(screen.getByRole("dialog", { name: "Join the video call" }))
        .getByRole("button", { name: "Join video call" })
    );

    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    expect(activeCall).toHaveAttribute("aria-modal", "true");
    expect(backgroundAction.closest('[aria-hidden="true"]')).not.toBeNull();
    const more = within(activeCall).getByRole("button", {
      name: "Open call menu"
    });
    const workspace = within(activeCall).getByRole("region", { name: "Call workspace" });
    expect(more).toHaveAttribute("aria-expanded", "false");
    expect(workspace).not.toHaveClass("mobile-open");
    await user.click(more);
    expect(more).toHaveAttribute("aria-expanded", "true");
    expect(workspace).toHaveClass("mobile-open");
    const callMenu = within(activeCall).getByRole("dialog", { name: "Call menu" });
    await waitFor(() =>
      expect(callMenu).toContainElement(document.activeElement as HTMLElement)
    );

    backgroundAction.focus();
    expect(callMenu).toContainElement(document.activeElement as HTMLElement);
    await user.tab();
    expect(callMenu).toContainElement(document.activeElement as HTMLElement);

    await user.keyboard("{Escape}");
    await waitFor(() => expect(more).toHaveFocus());
    await user.click(within(activeCall).getByRole("button", { name: "Minimize" }));
    expect(await screen.findByRole("region", { name: "Design group" })).toBeVisible();
    expect(backgroundAction.closest('[aria-hidden="true"]')).toBeNull();
  });

  it("stops every local track before logout and keeps later page-exit cleanup idempotent", async () => {
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn() }
    });
    const api = apiWith(activeVideoCall);
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

    await user.click(await screen.findByRole("button", { name: "Join video call" }));
    const dialog = screen.getByRole("dialog", { name: "Join the video call" });
    await user.click(within(dialog).getByRole("button", { name: "Join video call" }));
    expect(await screen.findByText("Connected")).toBeVisible();

    const microphoneStop = vi.fn();
    const cameraStop = vi.fn();
    livekit.localParticipant.trackPublications.set("microphone", {
      track: { stop: microphoneStop }
    });
    livekit.localParticipant.trackPublications.set("camera", {
      track: { stop: cameraStop }
    });

    act(() => requestCallSessionTeardown());
    expect(microphoneStop).toHaveBeenCalledTimes(1);
    expect(cameraStop).toHaveBeenCalledTimes(1);
    expect(livekit.disconnect).toHaveBeenCalledTimes(1);
    expect(livekit.disconnect).toHaveBeenCalledWith(true);
    expect(api.endCall).not.toHaveBeenCalled();
    expect(screen.queryByText("Connected")).not.toBeInTheDocument();

    act(() => {
      window.dispatchEvent(new Event("beforeunload"));
      window.dispatchEvent(new Event("pagehide"));
    });
    expect(microphoneStop).toHaveBeenCalledTimes(1);
    expect(cameraStop).toHaveBeenCalledTimes(1);
    expect(livekit.disconnect).toHaveBeenCalledTimes(1);
  });
});
