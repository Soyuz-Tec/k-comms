import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter, useLocation, useNavigate } from "react-router";
import type { Call, Conversation } from "../../types";

/*
 * Route-transition continuity, measured rather than reasoned about.
 *
 * The existing provider test mocks CallPanel and counts its mounts. That
 * proves the panel is not remounted, which is necessary but not the claim the
 * increment actually rests on: that navigating away from a call preserves one
 * room, one hook, the attached tracks and the publication state, and
 * republishes nothing.
 *
 * So this one renders the *real* panel over a mocked LiveKit and counts what
 * LiveKit is asked to do. Every assertion here is something that would break
 * silently if a later change re-parented the media tree.
 */
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
  /** Every Room ever constructed. One hook means one entry. */
  roomsConstructed: [] as Record<string, unknown>[],
  connect: vi.fn().mockResolvedValue(undefined),
  disconnect: vi.fn().mockResolvedValue(undefined),
  startAudio: vi.fn().mockResolvedValue(undefined),
  startVideo: vi.fn().mockResolvedValue(undefined),
  switchActiveDevice: vi.fn().mockResolvedValue(undefined),
  getLocalDevices: vi.fn().mockResolvedValue([]),
  canPlaybackAudio: true,
  canPlaybackVideo: true,
  supportsVP9: false,
  localParticipant: {
    sid: "local-sid",
    identity: "user-1",
    name: "Ada",
    isLocal: true,
    isMicrophoneEnabled: false,
    isCameraEnabled: false,
    isScreenShareEnabled: false,
    isSpeaking: false,
    trackPublications: new Map(),
    getTrackPublications: () => [],
    setMicrophoneEnabled: vi.fn().mockResolvedValue(undefined),
    setCameraEnabled: vi.fn().mockResolvedValue(undefined),
    setScreenShareEnabled: vi.fn().mockResolvedValue(undefined)
  }
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
      livekit.roomsConstructed.push(options);
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

const activeCall: Call = {
  id: "call-1",
  conversation_id: conversation.id,
  started_by_user_id: "user-1",
  media_kind: "audio",
  status: "active",
  started_at: "2026-07-15T10:00:00Z",
  expires_at: "2026-07-15T18:00:00Z",
  can_end: true
};

/*
 * CallApi carries both the generic and the audio-specific methods; the panel
 * prefers the audio ones for an audio call, so both are stubbed rather than
 * guessing which path is taken.
 */
const api = vi.hoisted(() => ({
  call: vi.fn(),
  joinCall: vi.fn(),
  startCall: vi.fn(),
  endCall: vi.fn(),
  audioCall: vi.fn(),
  joinAudioCall: vi.fn(),
  startAudioCall: vi.fn(),
  endAudioCall: vi.fn(),
  socketTicket: vi.fn()
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api,
    session: { user: { id: "user-1", display_name: "Ada" } }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    audioCallsAvailable: true,
    videoCallsAvailable: true,
    loading: false,
    capabilities: { allow_audio_calls: true, allow_video_calls: true }
  })
}));

const { CallSessionProvider, useCallSession } = await import("./CallSessionProvider");

function Harness() {
  const { launchCall } = useCallSession();
  const location = useLocation();
  const navigate = useNavigate();
  return (
    <main>
      <output aria-label="route">{location.pathname}</output>
      <button type="button" onClick={() => launchCall(conversation, "audio")}>Start the call</button>
      <button type="button" onClick={() => navigate("/app/files")}>Open files</button>
      <button type="button" onClick={() => navigate("/app/directory")}>Open directory</button>
      <button type="button" onClick={() => navigate("/app")}>Back to inbox</button>
    </main>
  );
}

function renderProvider() {
  return render(
    <MemoryRouter initialEntries={["/app"]}>
      <CallSessionProvider>
        <Harness />
      </CallSessionProvider>
    </MemoryRouter>
  );
}

/** What LiveKit has been asked to do, as one comparable snapshot. */
function livekitActivity() {
  return {
    rooms: livekit.roomsConstructed.length,
    connects: livekit.connect.mock.calls.length,
    disconnects: livekit.disconnect.mock.calls.length,
    microphonePublishes: livekit.localParticipant.setMicrophoneEnabled.mock.calls.length,
    cameraPublishes: livekit.localParticipant.setCameraEnabled.mock.calls.length
  };
}

async function joinCall(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByRole("button", { name: "Start the call" }));
  const dialog = await screen.findByRole("dialog", { name: /Join the audio call|Start an audio call/ });
  // Exact: the prejoin offers both "Join muted" and "Join with microphone",
  // and joining muted keeps the publication count at a known baseline.
  await user.click(within(dialog).getByRole("button", { name: "Join muted" }));
  await waitFor(() => expect(livekit.connect).toHaveBeenCalledTimes(1));
}

describe("call continuity across authenticated navigation", () => {
  beforeEach(() => {
    livekit.roomsConstructed = [];
    livekit.callbacks.clear();
    livekit.remoteParticipants.clear();
    livekit.connect.mockClear();
    livekit.disconnect.mockClear();
    livekit.localParticipant.setMicrophoneEnabled.mockClear();
    livekit.localParticipant.setCameraEnabled.mockClear();
    livekit.localParticipant.isMicrophoneEnabled = false;
    const session = {
      data: activeCall,
      credential: {
        server_url: "wss://media.example.test",
        participant_token: "memory-only-participant-token",
        expires_in: 300
      }
    };
    api.call.mockResolvedValue(activeCall);
    api.audioCall.mockResolvedValue(activeCall);
    api.joinCall.mockResolvedValue(session);
    api.joinAudioCall.mockResolvedValue(session);
    api.startCall.mockResolvedValue(session);
    api.startAudioCall.mockResolvedValue(session);
    api.socketTicket.mockResolvedValue({ ticket: "ticket", expires_in: 300 });
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn().mockResolvedValue({ getTracks: () => [] }) }
    });
  });

  it("keeps one room, one connection and no republish across route changes", async () => {
    const user = userEvent.setup();
    renderProvider();
    await joinCall(user);

    const afterJoin = livekitActivity();
    expect(afterJoin.rooms).toBe(1);
    expect(afterJoin.connects).toBe(1);

    // Three route changes, away and back.
    for (const route of ["Open files", "Open directory", "Back to inbox"]) {
      await user.click(screen.getByRole("button", { name: route }));
      await waitFor(() =>
        expect(screen.getByLabelText("route")).not.toHaveTextContent("__never__")
      );
    }

    // Nothing was asked of LiveKit by navigating. A second room, a second
    // connect, or another publish call would each be a different bug, and
    // each of them is invisible without counting.
    expect(livekitActivity()).toEqual(afterJoin);
  });

  it("never disconnects the room merely because the route changed", async () => {
    const user = userEvent.setup();
    renderProvider();
    await joinCall(user);

    await user.click(screen.getByRole("button", { name: "Open files" }));
    await waitFor(() => expect(screen.getByLabelText("route")).toHaveTextContent("/app/files"));

    expect(livekit.disconnect).not.toHaveBeenCalled();
  });

  it("keeps the same attached media element across navigation, without re-attaching", async () => {
    // Re-parenting the media DOM is the failure mode §2.1 exists to prevent:
    // a detached and re-attached <audio> drops the call's sound without
    // dropping the call, which looks like a network problem.
    const user = userEvent.setup();
    renderProvider();
    await joinCall(user);

    // A remote participant has to actually be publishing, or there is no
    // media element and the comparison below is two nulls proving nothing.
    const audio = document.createElement("audio");
    const remoteTrack = {
      kind: "audio",
      attach: vi.fn(() => audio),
      detach: vi.fn(() => [audio])
    };
    act(() => livekit.callbacks.get(livekit.events.TrackSubscribed)?.(remoteTrack));

    const before = document.querySelector("[data-k-comms-call-audio]");
    expect(before).not.toBeNull();
    expect(remoteTrack.attach).toHaveBeenCalledTimes(1);

    await user.click(screen.getByRole("button", { name: "Open directory" }));
    await waitFor(() => expect(screen.getByLabelText("route")).toHaveTextContent("/app/directory"));

    expect(document.querySelector("[data-k-comms-call-audio]")).toBe(before);
    // Navigating re-attached nothing and detached nothing.
    expect(remoteTrack.attach).toHaveBeenCalledTimes(1);
    expect(remoteTrack.detach).not.toHaveBeenCalled();
  });

  it("keeps the panel and its call identity mounted throughout", async () => {
    const user = userEvent.setup();
    renderProvider();
    await joinCall(user);

    const dock = await screen.findByRole("region", { name: "Design group" });

    await user.click(screen.getByRole("button", { name: "Open files" }));
    await waitFor(() => expect(screen.getByLabelText("route")).toHaveTextContent("/app/files"));

    // The same element, not an equivalent one rendered again.
    expect(screen.getByRole("region", { name: "Design group" })).toBe(dock);
  });
});
