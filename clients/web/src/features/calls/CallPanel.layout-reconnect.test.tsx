import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Call, Conversation } from "../../types";
import { CallPanel } from "./CallPanel";
import {
  resetProtectedSurfacesForTest,
  setProtectedSurface
} from "../experience/companion-collision";

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

const activeAudioCall: Call = {
  ...activeVideoCall,
  id: "audio-call-1",
  media_kind: "audio"
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

function useMobileCallLayout() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn().mockReturnValue({
      matches: true,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn()
    })
  });
}

describe("CallPanel calls", () => {
  beforeEach(() => {
    // Collision signals are module state; one test must not leak into the next.
    resetProtectedSurfacesForTest();
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

  it("keeps a mobile audio call expanded with an avatar stage, visible controls, and closable menus", async () => {
    useMobileCallLayout();
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

    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    expect(activeCall).toHaveAttribute("aria-modal", "true");
    expect(activeCall).toHaveClass("active-call-screen", "audio-call-screen");
    expect(activeCall).not.toHaveClass("minimized");
    const progress = within(activeCall).getByLabelText("Call progress");
    const headingSummary = activeCall.querySelector(".call-heading-summary") as HTMLElement;
    expect(headingSummary).toContainElement(within(activeCall).getByRole("heading", {
      name: "Design group"
    }));
    expect(within(progress).getByText("·")).toHaveAttribute("aria-hidden", "true");
    const participantCount = within(progress).getByRole("status", {
      name: "1 participant"
    });
    expect(participantCount.querySelector(".call-participant-count-number"))
      .toHaveTextContent("1");
    expect(participantCount.querySelector(".call-participant-count-word"))
      .toHaveTextContent("participant");
    expect(within(progress).getByText("Connected"))
      .toHaveClass("call-status-connected");

    const participantStage = within(activeCall).getByRole("region", {
      name: "Audio call participants"
    });
    expect(within(participantStage).getByRole("listitem", {
      name: "Ada (you), Muted"
    })).toBeVisible();
    expect(within(participantStage).getByText("Only you are in the call."))
      .toBeVisible();
    expect(participantStage.querySelector(".audio-participant-avatar"))
      .toHaveTextContent("A");

    const actions = activeCall.querySelector(".audio-call-actions") as HTMLElement;
    expect(within(actions).getAllByRole("button")).toHaveLength(3);
    expect(Array.from(actions.querySelectorAll(".call-action-label"))
      .map((label) => label.textContent)).toEqual(["Mic", "People", "Leave"]);
    expect(within(actions).getByRole("button", { name: "Unmute microphone" }))
      .toBeVisible();
    expect(within(actions).getByRole("button", { name: "People" })).toBeVisible();
    expect(within(actions).getByRole("button", { name: "Leave call" })).toBeVisible();
    expect(within(actions).queryByRole("button", { name: "End for everyone" }))
      .not.toBeInTheDocument();

    const menuTrigger = within(activeCall).getByRole("button", {
      name: "Open call menu"
    });
    await user.click(menuTrigger);
    expect(menuTrigger).toHaveAttribute("aria-expanded", "true");
    let callMenu = within(activeCall).getByRole("dialog", { name: "Call menu" });
    const closeMenu = within(callMenu).getByRole("button", {
      name: "Close call menu"
    });
    await waitFor(() => expect(closeMenu).toHaveFocus());
    await user.keyboard("{Escape}");
    expect(menuTrigger).toHaveAttribute("aria-expanded", "false");
    await waitFor(() => expect(menuTrigger).toHaveFocus());

    const people = within(actions).getByRole("button", { name: "People" });
    await user.click(people);
    expect(people).toHaveAttribute("aria-expanded", "true");
    callMenu = within(activeCall).getByRole("dialog", { name: "Call menu" });
    expect(within(
      within(callMenu).getByRole("navigation", { name: "Call workspace" })
    ).getByRole("button", { name: "People" }))
      .toHaveAttribute("aria-pressed", "true");
    expect(within(callMenu).getByText("Ada (you)")).toBeVisible();
    await user.click(within(callMenu).getByRole("button", {
      name: "Close call menu"
    }));
    expect(people).toHaveAttribute("aria-expanded", "false");
    await waitFor(() => expect(people).toHaveFocus());
  });

  it("moves owner-only ending into the mobile menu and requires confirmation", async () => {
    useMobileCallLayout();
    const api = apiWith(activeAudioCall);
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
    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    const actions = activeCall.querySelector(".audio-call-actions") as HTMLElement;
    expect(within(actions).queryByRole("button", { name: "End for everyone" }))
      .not.toBeInTheDocument();

    await user.click(within(activeCall).getByRole("button", {
      name: "Open call menu"
    }));
    await user.click(within(activeCall).getByRole("button", {
      name: "End for everyone"
    }));
    let confirmation = screen.getByRole("dialog", {
      name: "End call for everyone?"
    });
    expect(confirmation).toHaveTextContent(
      "This ends the call for every participant."
    );
    await user.click(within(confirmation).getByRole("button", { name: "Cancel" }));
    expect(api.endCall).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog", { name: "End call for everyone?" }))
      .not.toBeInTheDocument();
    const callMenu = screen.getByRole("dialog", { name: "Call menu" });
    const endForEveryone = within(callMenu).getByRole("button", {
      name: "End for everyone"
    });
    await waitFor(() => expect(endForEveryone).toHaveFocus());

    await user.click(endForEveryone);
    confirmation = screen.getByRole("dialog", { name: "End call for everyone?" });
    await user.click(within(confirmation).getByRole("button", {
      name: "End for everyone"
    }));

    await waitFor(() =>
      expect(api.endCall).toHaveBeenCalledWith(conversation.id, activeAudioCall.id)
    );
    expect(livekit.disconnect).toHaveBeenCalledWith(true);
  });

  it("expands a desktop-minimized audio call when the viewport becomes mobile", async () => {
    let changeListener: (() => void) | undefined;
    const query = {
      matches: false,
      addEventListener: vi.fn((_event: string, listener: () => void) => {
        changeListener = listener;
      }),
      removeEventListener: vi.fn()
    };
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue(query)
    });
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn() }
    });
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
    expect(await screen.findByRole("region", { name: "Design group" }))
      .toHaveClass("minimized");

    act(() => {
      query.matches = true;
      changeListener?.();
    });

    await waitFor(() =>
      expect(screen.getByRole("dialog", { name: "Design group" }))
        .not.toHaveClass("minimized")
    );
    expect(screen.getByRole("button", { name: "Open call menu" })).toBeVisible();
  });

  it("keeps critical call state and controls reachable while minimized", async () => {
    // Minimizing hides #active-call-details, which held the capture indicator
    // and every control. The companion capsule is what has to remain: a
    // minimized call that cannot report a live microphone, or be muted or
    // hung up, is the defect this covers.
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue({
        matches: false,
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

    const dock = await screen.findByRole("region", { name: "Design group" });
    expect(dock).toHaveClass("minimized");

    // State, in words rather than by icon or hover alone.
    expect(within(dock).getByRole("status", { name: "Call status" }))
      .toHaveTextContent("Microphone off");

    // Actions, without first restoring the panel.
    const controls = within(dock).getByRole("group", { name: "Call controls" });
    expect(within(controls).getByRole("button", { name: "Unmute microphone" })).toBeEnabled();
    expect(within(controls).getByRole("button", { name: "Leave call" })).toBeEnabled();

    // The restore target stays visible: minimize must never be a one-way door.
    expect(within(dock).getByRole("button", { name: "Show call" })).toBeVisible();
  });

  it("offers keyboard and preset placement on the minimized companion", async () => {
    // The companion floats over the user's work, so it has to be movable --
    // and movable without a pointer. Dragging is an enhancement, not the only
    // placement mechanism.
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue({
        matches: false,
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

    const dock = await screen.findByRole("region", { name: "Design group" });
    expect(dock).toHaveClass("minimized");

    const placement = within(dock).getByRole("group", { name: "Call panel position" });
    expect(within(placement).getByRole("button", { name: "Move call panel" })).toBeVisible();

    // It starts bottom-right, and every corner is one click away.
    const bottomRight = within(placement)
      .getByRole("button", { name: "Move call panel to bottom right" });
    expect(bottomRight).toHaveAttribute("aria-pressed", "true");

    const topLeft = within(placement).getByRole("button", { name: "Move call panel to top left" });
    await user.click(topLeft);
    expect(topLeft).toHaveAttribute("aria-pressed", "true");
    expect(bottomRight).toHaveAttribute("aria-pressed", "false");
  });

  it("does not offer placement controls on an expanded call", async () => {
    // Expanded, the dock's position belongs to CSS -- and on the Immersive
    // stage it fills the viewport. There is nothing to place.
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: vi.fn() }
    });
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
    await user.click(await screen.findByRole("button", { name: "Show call" }));

    expect(screen.queryByRole("group", { name: "Call panel position" })).toBeNull();
  });

  it("yields the companion off a drawable canvas, and reduces it while drawing", async () => {
    // The companion floats over whatever the user is doing. A whiteboard's
    // drawable plane and its native controls are protected zones: the panel
    // moves off them, and gets out of the way entirely while a pen or a text
    // editor is active.
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue({
        matches: false,
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

    const dock = await screen.findByRole("region", { name: "Design group" });
    expect(dock).toHaveClass("minimized");
    expect(dock).not.toHaveAttribute("data-yielded");

    // A canvas appears: move off it, but keep the controls.
    act(() => setProtectedSurface("canvasVisible", true));
    await waitFor(() => expect(dock).toHaveAttribute("data-yielded", "canvas-visible"));
    expect(
      within(dock).getByRole("group", { name: "Call controls" })
    ).toBeInTheDocument();

    // A stylus goes down: reduce, and stay reduced until it lifts.
    act(() => setProtectedSurface("canvasEditing", true));
    await waitFor(() => expect(dock).toHaveAttribute("data-yielded", "canvas-editing"));
    // Critical state survives every degree of yielding -- that is the floor.
    expect(within(dock).getByRole("status", { name: "Call status" })).toHaveTextContent(
      "Microphone off"
    );

    act(() => setProtectedSurface("canvasEditing", false));
    await waitFor(() => expect(dock).toHaveAttribute("data-yielded", "canvas-visible"));

    // Canvas gone: the user's own placement comes back.
    act(() => setProtectedSurface("canvasVisible", false));
    await waitFor(() => expect(dock).not.toHaveAttribute("data-yielded"));
  });

  it("yields the companion to the virtual keyboard", async () => {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue({
        matches: false,
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

    const dock = await screen.findByRole("region", { name: "Design group" });
    act(() => setProtectedSurface("keyboardOpen", true));

    await waitFor(() => expect(dock).toHaveAttribute("data-yielded", "keyboard-open"));
    // Still leaveable with the keyboard up: yielding never removes the
    // safety-critical controls.
    expect(
      within(dock).getByRole("button", { name: "Leave call" })
    ).toBeEnabled();
  });

  it("announces reconnecting and restores mobile audio controls after reconnection", async () => {
    useMobileCallLayout();
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
    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    const progress = within(activeCall).getByLabelText("Call progress");
    const microphone = within(activeCall).getByRole("button", {
      name: "Unmute microphone"
    });

    act(() => livekit.callbacks.get(livekit.events.Reconnecting)?.());
    expect(within(progress).getByText("Reconnecting"))
      .toHaveAttribute("aria-live", "polite");
    expect(activeCall.querySelector(".call-heading-summary"))
      .toHaveClass("has-call-status");
    expect(microphone).toBeDisabled();
    expect(within(activeCall).getByRole("button", { name: "Leave call" }))
      .toBeEnabled();

    act(() => livekit.callbacks.get(livekit.events.Reconnected)?.());
    expect(within(progress).getByText("Connected"))
      .toHaveClass("call-status-connected");
    expect(activeCall.querySelector(".call-heading-summary"))
      .not.toHaveClass("has-call-status");
    expect(microphone).toBeEnabled();
  });

  it("shows five labeled mobile video controls and prioritizes sharing and speaking participants", async () => {
    useMobileCallLayout();
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeVideoCall)}
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
    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    const actions = activeCall.querySelector(".audio-call-actions") as HTMLElement;
    expect(within(actions).getAllByRole("button")).toHaveLength(5);
    expect(Array.from(actions.querySelectorAll(".call-action-label"))
      .map((label) => label.textContent))
      .toEqual(["Mic", "Camera", "Screen", "People", "Leave"]);
    expect(within(actions).getByRole("button", { name: "Unmute microphone" }))
      .toBeVisible();
    const camera = within(actions).getByRole("button", { name: "Turn camera on" });
    expect(camera).toBeVisible();
    await user.click(camera);
    expect(await within(activeCall).findByText("Starting video…")).toBeVisible();
    expect(within(actions).getByRole("button", { name: "Share screen" }))
      .toBeVisible();

    const grace = remoteParticipant("user-2", "Grace", { speaking: true });
    const linus = remoteParticipant("user-3", "Linus", { screenSharing: true });
    livekit.remoteParticipants.set("user-2", grace.participant);
    livekit.remoteParticipants.set("user-3", linus.participant);
    act(() => livekit.callbacks.get(livekit.events.ParticipantConnected)?.());

    const progress = within(activeCall).getByLabelText("Call progress");
    const participantCount = within(progress).getByRole("status", {
      name: "3 participants"
    });
    expect(participantCount.querySelector(".call-participant-count-number"))
      .toHaveTextContent("3");
    expect(participantCount.querySelector(".call-participant-count-word"))
      .toHaveTextContent("participants");
    expect(participantCount.querySelector(".call-participant-count-icon .app-icon"))
      .toBeInTheDocument();
    const participantIds = within(activeCall)
      .getAllByRole("listitem")
      .filter((item) => item.hasAttribute("data-participant-id"))
      .map((item) => item.getAttribute("data-participant-id"));
    expect(participantIds).toEqual(["user-3", "user-2", "user-1"]);
    expect(within(activeCall).getByRole("listitem", {
      name: "Grace, Microphone on, Camera on, Speaking"
    })).toBeVisible();
  });

  it("persists the elder-friendly call-control label preference without changing accessible names", async () => {
    useMobileCallLayout();
    const user = userEvent.setup();
    render(
      <CallPanel
        api={apiWith(activeVideoCall)}
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

    const activeCall = await screen.findByRole("dialog", { name: "Design group" });
    expect(activeCall).toHaveAttribute("data-call-control-labels", "visible");
    await user.click(within(activeCall).getByRole("button", {
      name: "Open call menu"
    }));
    const callMenu = within(activeCall).getByRole("dialog", { name: "Call menu" });
    await user.click(within(callMenu).getByRole("button", {
      name: "Hide labels"
    }));

    expect(activeCall).toHaveAttribute("data-call-control-labels", "hidden");
    expect(window.localStorage.getItem("k-comms.call-control-labels.v1"))
      .toBe("hidden");
    expect(within(callMenu).getByRole("button", { name: "Show labels" }))
      .toBeVisible();
    expect(within(activeCall).getByRole("button", { name: "People" }))
      .toBeVisible();
    expect(within(callMenu).getByText("Control labels hidden"))
      .toBeInTheDocument();
    await user.click(within(callMenu).getByRole("button", {
      name: "Close call menu"
    }));
    const callStage = activeCall.querySelector(".call-stage");
    await waitFor(() => {
      expect(callStage).not.toHaveAttribute("inert");
      expect(callStage).not.toHaveAttribute("aria-hidden");
    });
    expect(within(activeCall).getByRole("button", {
      name: "Unmute microphone"
    })).toBeVisible();
    expect(within(activeCall).getByRole("button", {
      name: "Turn camera on"
    })).toBeVisible();

    await user.click(within(activeCall).getByRole("button", {
      name: "Open call menu"
    }));
    fireEvent.pointerDown(activeCall.querySelector(".active-call-details")!);
    expect(within(activeCall).queryByRole("dialog", { name: "Call menu" }))
      .not.toBeInTheDocument();
  });
});
