import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
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

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}
