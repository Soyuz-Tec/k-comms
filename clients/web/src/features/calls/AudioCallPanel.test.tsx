import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { AudioCall, Conversation } from "../../types";
import { AudioCallPanel } from "./AudioCallPanel";

const livekit = vi.hoisted(() => ({
  events: {
    ParticipantConnected: "participantConnected",
    ParticipantDisconnected: "participantDisconnected",
    TrackMuted: "trackMuted",
    TrackUnmuted: "trackUnmuted",
    ActiveSpeakersChanged: "activeSpeakersChanged",
    TrackSubscribed: "trackSubscribed",
    TrackUnsubscribed: "trackUnsubscribed",
    Reconnecting: "reconnecting",
    Reconnected: "reconnected",
    ConnectionStateChanged: "connectionStateChanged",
    AudioPlaybackStatusChanged: "audioPlaybackChanged",
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
    isSpeaking: false,
    setMicrophoneEnabled: vi.fn()
  },
  getLocalDevices: vi.fn(),
  connect: vi.fn(),
  disconnect: vi.fn(),
  startAudio: vi.fn(),
  switchActiveDevice: vi.fn(),
  canPlaybackAudio: true
}));

vi.mock("livekit-client", () => ({
  ConnectionState: { Connected: "connected", Disconnected: "disconnected", Connecting: "connecting", Reconnecting: "reconnecting", SignalReconnecting: "signalReconnecting" },
  DisconnectReason: { PARTICIPANT_REMOVED: 4, ROOM_DELETED: 5 },
  RoomEvent: livekit.events,
  Track: { Kind: { Audio: "audio", Video: "video" } },
  Room: class MockRoom {
    static getLocalDevices(kind: MediaDeviceKind, requestPermissions?: boolean) {
      return livekit.getLocalDevices(kind, requestPermissions);
    }
    remoteParticipants = livekit.remoteParticipants;
    localParticipant = livekit.localParticipant;
    get canPlaybackAudio() { return livekit.canPlaybackAudio; }
    on(event: string, callback: (...args: unknown[]) => void) {
      livekit.callbacks.set(event, callback);
      return this;
    }
    connect(url: string, token: string, options: unknown) { return livekit.connect(url, token, options); }
    disconnect(stopTracks?: boolean) { return livekit.disconnect(stopTracks); }
    startAudio() { return livekit.startAudio(); }
    switchActiveDevice(kind: MediaDeviceKind, deviceId: string, exact?: boolean) { return livekit.switchActiveDevice(kind, deviceId, exact); }
  }
}));

const conversation: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "General",
  visibility: "tenant",
  latest_sequence: 0,
  inserted_at: "2026-07-15T10:00:00Z",
  updated_at: "2026-07-15T10:00:00Z"
};

const activeCall: AudioCall = {
  id: "call-1",
  conversation_id: "conversation-1",
  started_by_user_id: "user-1",
  status: "active",
  started_at: "2026-07-15T10:00:00Z",
  expires_at: "2026-07-15T11:00:00Z",
  can_end: true
};

const credential = {
  data: activeCall,
  credential: {
    server_url: "wss://media.example.test",
    participant_token: "memory-only-participant-token",
    expires_in: 300
  }
};

function microphone(deviceId: string, label: string): MediaDeviceInfo {
  return { deviceId, label, kind: "audioinput", groupId: "group-1", toJSON: () => ({}) };
}

function apiWith(active: AudioCall | null) {
  return {
    audioCall: vi.fn().mockResolvedValue(active),
    startAudioCall: vi.fn().mockResolvedValue(credential),
    joinAudioCall: vi.fn().mockResolvedValue(credential),
    endAudioCall: vi.fn().mockResolvedValue({ ...activeCall, status: "ended", ended_at: "2026-07-15T10:30:00Z" })
  } as unknown as ApiClient;
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

describe("AudioCallPanel", () => {
  beforeEach(() => {
    livekit.callbacks.clear();
    livekit.remoteParticipants.clear();
    livekit.localParticipant.isMicrophoneEnabled = false;
    livekit.localParticipant.isSpeaking = false;
    livekit.getLocalDevices.mockReset().mockResolvedValue([
      microphone("mic-1", "Built-in microphone"),
      microphone("mic-2", "USB microphone")
    ]);
    livekit.connect.mockReset().mockResolvedValue(undefined);
    livekit.disconnect.mockReset().mockResolvedValue(undefined);
    livekit.startAudio.mockReset().mockResolvedValue(undefined);
    livekit.switchActiveDevice.mockReset().mockResolvedValue(true);
    livekit.canPlaybackAudio = true;
    livekit.localParticipant.setMicrophoneEnabled.mockReset().mockImplementation(async (enabled: boolean) => {
      livekit.localParticipant.isMicrophoneEnabled = enabled;
      return undefined;
    });
    window.localStorage.clear();
    window.sessionStorage.clear();
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia: vi.fn() } });
  });

  it("starts muted, renders subscribed remote audio, and destroys tracks on cleanup without persisting the token", async () => {
    const api = apiWith(null);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Start audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));

    expect(await screen.findByText("Connected")).toBeVisible();
    expect(api.startAudioCall).toHaveBeenCalledWith("conversation-1");
    expect(livekit.connect).toHaveBeenCalledWith("wss://media.example.test", "memory-only-participant-token", { autoSubscribe: true });
    expect(livekit.localParticipant.setMicrophoneEnabled).not.toHaveBeenCalled();
    expect(screen.getByText("Ada (you)")).toBeVisible();
    expect(screen.getByText("Muted")).toBeVisible();

    livekit.remoteParticipants.set("user-2", {
      sid: "remote-sid",
      identity: "user-2",
      name: "Grace",
      isLocal: false,
      isMicrophoneEnabled: true,
      isSpeaking: true
    });
    const audio = document.createElement("audio");
    const remoteTrack = { kind: "audio", attach: vi.fn(() => audio), detach: vi.fn(() => [audio]) };
    act(() => livekit.callbacks.get(livekit.events.TrackSubscribed)?.(remoteTrack));
    expect(await screen.findByText("Grace")).toBeVisible();
    expect(document.querySelector("[data-k-comms-call-audio='remote']")).toBe(audio);

    expect(window.localStorage.length).toBe(0);
    expect(window.sessionStorage.length).toBe(0);
    expect(document.body.textContent).not.toContain("memory-only-participant-token");

    view.unmount();
    expect(livekit.disconnect).toHaveBeenCalledWith(true);
  });

  it("attaches a remote track that subscribes before the connected call dock mounts", async () => {
    const api = apiWith(activeCall);
    const user = userEvent.setup();
    const audio = document.createElement("audio");
    const remoteTrack = {
      sid: "remote-track-sid",
      mediaStreamTrack: { id: "remote-media-track" },
      kind: "audio",
      attach: vi.fn(() => audio),
      detach: vi.fn(() => [audio])
    };
    livekit.remoteParticipants.set("user-2", {
      sid: "remote-sid",
      identity: "user-2",
      name: "Grace",
      isLocal: false,
      isMicrophoneEnabled: true,
      isSpeaking: false,
      audioTrackPublications: new Map([
        ["remote-track-sid", { isSubscribed: true, track: remoteTrack }]
      ])
    });
    livekit.connect.mockImplementationOnce(async () => {
      livekit.callbacks.get(livekit.events.TrackSubscribed)?.(remoteTrack);
    });

    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);
    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));

    expect(await screen.findByText("Connected")).toBeVisible();
    await waitFor(() => {
      expect(document.querySelector("[data-k-comms-call-audio='remote']")).toBe(audio);
    });
    expect(remoteTrack.attach).toHaveBeenCalledTimes(1);
  });

  it("joins with the selected microphone, supports device and mute controls, reconnects, and ends for everyone", async () => {
    const api = apiWith(activeCall);
    const user = userEvent.setup();
    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.selectOptions(screen.getByRole("combobox"), "mic-2");
    await user.click(screen.getByRole("button", { name: "Join with microphone" }));

    expect(await screen.findByRole("button", { name: "Mute microphone" })).toBeVisible();
    expect(api.joinAudioCall).toHaveBeenCalledWith("conversation-1", "call-1");
    expect(livekit.localParticipant.setMicrophoneEnabled).toHaveBeenCalledWith(true, expect.objectContaining({ deviceId: "mic-2" }));

    await user.selectOptions(screen.getByRole("combobox"), "mic-1");
    expect(livekit.switchActiveDevice).toHaveBeenCalledWith("audioinput", "mic-1", true);
    await user.click(screen.getByRole("button", { name: "Mute microphone" }));
    expect(livekit.localParticipant.setMicrophoneEnabled).toHaveBeenLastCalledWith(false);
    expect(await screen.findByRole("button", { name: "Unmute microphone" })).toBeVisible();

    act(() => livekit.callbacks.get(livekit.events.Reconnecting)?.());
    expect(screen.getByText("Reconnecting")).toBeVisible();
    act(() => livekit.callbacks.get(livekit.events.Reconnected)?.());
    expect(screen.getByText("Connected")).toBeVisible();

    livekit.canPlaybackAudio = false;
    act(() => livekit.callbacks.get(livekit.events.AudioPlaybackStatusChanged)?.(false));
    await user.click(await screen.findByRole("button", { name: "Enable call audio" }));
    expect(livekit.startAudio).toHaveBeenCalledTimes(2);

    await user.click(screen.getByRole("button", { name: "End for everyone" }));
    await waitFor(() => expect(api.endAudioCall).toHaveBeenCalledWith("conversation-1", "call-1"));
    expect(livekit.disconnect).toHaveBeenCalledWith(true);
  });

  it("keeps the prejoin dialog open and does not create a call when microphone permission is denied", async () => {
    const api = apiWith(null);
    const user = userEvent.setup();
    livekit.getLocalDevices
      .mockResolvedValueOnce([microphone("mic-1", "Built-in microphone")])
      .mockRejectedValueOnce(new DOMException("denied", "NotAllowedError"));
    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Start audio call" }));
    await user.click(screen.getByRole("button", { name: "Join with microphone" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Microphone permission was blocked");
    expect(screen.getByRole("dialog", { name: "Start an audio call" })).toBeVisible();
    expect(api.startAudioCall).not.toHaveBeenCalled();
  });

  it("keeps a failed provider join visible and retryable after the prejoin dialog closes", async () => {
    const api = apiWith(activeCall);
    vi.mocked(api.joinAudioCall).mockRejectedValueOnce(new Error("media provider unavailable"));
    const user = userEvent.setup();
    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Unable to join the audio call. media provider unavailable"
    );
    expect(screen.getByRole("button", { name: "Retry audio call" })).toBeEnabled();
  });

  it("lets the starter end a call when the provider credential succeeds but room connection fails", async () => {
    const api = apiWith(null);
    livekit.connect.mockRejectedValueOnce(new Error("signaling unavailable"));
    const user = userEvent.setup();
    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Start audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Unable to join the audio call. signaling unavailable"
    );
    await user.click(screen.getByRole("button", { name: "End for everyone" }));

    await waitFor(() => expect(api.endAudioCall).toHaveBeenCalledWith("conversation-1", "call-1"));
    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();
    expect(screen.queryByText("Unable to join the audio call. signaling unavailable")).not.toBeInTheDocument();
  });

  it("disconnects and clears media immediately when the call is ended over realtime", async () => {
    const api = apiWith(activeCall);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    expect(await screen.findByText("Connected")).toBeVisible();

    const audio = document.createElement("audio");
    const remoteTrack = { kind: "audio", attach: vi.fn(() => audio), detach: vi.fn(() => [audio]) };
    act(() => livekit.callbacks.get(livekit.events.TrackSubscribed)?.(remoteTrack));
    expect(document.querySelector("[data-k-comms-call-audio='remote']")).toBe(audio);

    view.rerender(<AudioCallPanel
      api={api}
      conversation={conversation}
      enabled
      currentUserDisplayName="Ada"
      realtimeEvent={{
        ...activeCall,
        status: "ended",
        ended_at: "2026-07-15T10:30:00Z",
        end_reason: "ended_by_user"
      }}
    />);

    await waitFor(() => expect(livekit.disconnect).toHaveBeenCalledWith(true));
    expect(document.querySelector("[data-k-comms-call-audio='remote']")).toBeNull();
    expect(screen.getByRole("button", { name: "Start audio call" })).toBeVisible();
    expect(screen.getByText("The audio call was ended for everyone.")).toBeInTheDocument();
  });

  it("treats participant removal as terminal access revocation without polling or rejoining", async () => {
    const api = apiWith(activeCall);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    expect(await screen.findByText("Connected")).toBeVisible();

    const audio = document.createElement("audio");
    const remoteTrack = { kind: "audio", attach: vi.fn(() => audio), detach: vi.fn(() => [audio]) };
    act(() => livekit.callbacks.get(livekit.events.TrackSubscribed)?.(remoteTrack));
    expect(document.querySelector("[data-k-comms-call-audio='remote']")).toBe(audio);

    act(() => livekit.callbacks.get(livekit.events.Disconnected)?.(4));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Your access to this audio call was revoked. Sign in again or contact an administrator."
    );
    expect(screen.getByRole("button", { name: "Audio access revoked" })).toBeDisabled();
    expect(document.querySelector("[data-k-comms-call-audio='remote']")).toBeNull();
    expect(screen.queryByText("Connected")).not.toBeInTheDocument();
    expect(livekit.disconnect).toHaveBeenCalledWith(true);

    view.rerender(<AudioCallPanel
      api={api}
      conversation={conversation}
      enabled
      currentUserDisplayName="Ada"
      realtimeEvent={activeCall}
    />);
    window.dispatchEvent(new Event("focus"));
    await act(async () => Promise.resolve());

    expect(api.audioCall).toHaveBeenCalledTimes(1);
    expect(api.joinAudioCall).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Audio access revoked" })).toBeDisabled();
  });

  it("shows ended-for-everyone when LiveKit reports that the room was deleted", async () => {
    const api = apiWith(activeCall);
    const user = userEvent.setup();
    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    expect(await screen.findByText("Connected")).toBeVisible();

    act(() => livekit.callbacks.get(livekit.events.Disconnected)?.(5));

    expect(await screen.findByRole("status")).toHaveTextContent("The audio call was ended for everyone.");
    expect(screen.getByRole("button", { name: "Start audio call" })).toBeEnabled();
    expect(screen.queryByText("Connected")).not.toBeInTheDocument();
    expect(livekit.disconnect).toHaveBeenCalledWith(true);
  });

  it("retains the bounded status refresh for an unexpected network disconnect", async () => {
    const api = apiWith(activeCall);
    const refreshRequest = deferred<AudioCall | null>();
    vi.mocked(api.audioCall)
      .mockResolvedValueOnce(activeCall)
      .mockReturnValueOnce(refreshRequest.promise);
    const user = userEvent.setup();
    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    expect(await screen.findByText("Connected")).toBeVisible();

    act(() => livekit.callbacks.get(livekit.events.Disconnected)?.(9));

    await waitFor(() => expect(api.audioCall).toHaveBeenCalledTimes(2));
    expect(screen.queryByRole("button", { name: "Audio access revoked" })).not.toBeInTheDocument();

    await act(async () => {
      refreshRequest.resolve(activeCall);
      await refreshRequest.promise;
    });
    expect(screen.getByRole("button", { name: "Join audio call" })).toBeEnabled();
  });

  it("ignores a late join credential after realtime ends the call", async () => {
    const api = apiWith(activeCall);
    const joinRequest = deferred<typeof credential>();
    vi.mocked(api.joinAudioCall).mockReturnValueOnce(joinRequest.promise);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    await waitFor(() => expect(api.joinAudioCall).toHaveBeenCalledWith("conversation-1", "call-1"));

    view.rerender(<AudioCallPanel
      api={api}
      conversation={conversation}
      enabled
      currentUserDisplayName="Ada"
      realtimeEvent={{
        ...activeCall,
        status: "ended",
        ended_at: "2026-07-15T10:30:00Z",
        end_reason: "ended_by_user"
      }}
    />);
    expect(await screen.findByText("The audio call was ended for everyone.")).toBeInTheDocument();

    await act(async () => {
      joinRequest.resolve(credential);
      await joinRequest.promise;
    });

    expect(livekit.connect).not.toHaveBeenCalled();
    expect(livekit.startAudio).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Start audio call" })).toBeVisible();
  });

  it("disconnects a provisional room and ignores a late connect completion after realtime ends", async () => {
    const api = apiWith(activeCall);
    const connectRequest = deferred<void>();
    livekit.connect.mockReturnValueOnce(connectRequest.promise);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    await waitFor(() => expect(livekit.connect).toHaveBeenCalledTimes(1));

    view.rerender(<AudioCallPanel
      api={api}
      conversation={conversation}
      enabled
      currentUserDisplayName="Ada"
      realtimeEvent={{
        ...activeCall,
        status: "ended",
        ended_at: "2026-07-15T10:30:00Z",
        end_reason: "ended_by_user"
      }}
    />);
    await waitFor(() => expect(livekit.disconnect).toHaveBeenCalledWith(true));

    await act(async () => {
      connectRequest.resolve();
      await connectRequest.promise;
    });

    expect(livekit.startAudio).not.toHaveBeenCalled();
    expect(screen.queryByText("Connected")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Start audio call" })).toBeVisible();
  });

  it("invalidates a pending start request when the audio capability is disabled", async () => {
    const api = apiWith(null);
    const startRequest = deferred<typeof credential>();
    vi.mocked(api.startAudioCall).mockReturnValueOnce(startRequest.promise);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Start audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    await waitFor(() => expect(api.startAudioCall).toHaveBeenCalledWith("conversation-1"));

    view.rerender(<AudioCallPanel api={api} conversation={conversation} enabled={false} currentUserDisplayName="Ada" />);
    expect(await screen.findByRole("button", { name: "Audio calls disabled" })).toBeDisabled();

    await act(async () => {
      startRequest.resolve(credential);
      await startRequest.promise;
    });

    expect(livekit.connect).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Audio calls disabled" })).toBeDisabled();
  });

  it("lets the user cancel a pending start request without allowing its credential to connect", async () => {
    const api = apiWith(null);
    const startRequest = deferred<typeof credential>();
    vi.mocked(api.startAudioCall).mockReturnValueOnce(startRequest.promise);
    const user = userEvent.setup();
    render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Start audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    await waitFor(() => expect(api.startAudioCall).toHaveBeenCalledWith("conversation-1"));

    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();

    await act(async () => {
      startRequest.resolve(credential);
      await startRequest.promise;
    });

    expect(livekit.connect).not.toHaveBeenCalled();
    expect(screen.queryByText("Connected")).not.toBeInTheDocument();
  });

  it("invalidates a pending join request when the conversation changes", async () => {
    const api = apiWith(activeCall);
    const joinRequest = deferred<typeof credential>();
    const nextConversation = { ...conversation, id: "conversation-2", title: "Support" };
    vi.mocked(api.audioCall).mockImplementation(async (conversationId) => (
      conversationId === conversation.id ? activeCall : null
    ));
    vi.mocked(api.joinAudioCall).mockReturnValueOnce(joinRequest.promise);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    await waitFor(() => expect(api.joinAudioCall).toHaveBeenCalledWith("conversation-1", "call-1"));

    view.rerender(<AudioCallPanel api={api} conversation={nextConversation} enabled currentUserDisplayName="Ada" />);
    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();

    await act(async () => {
      joinRequest.resolve(credential);
      await joinRequest.promise;
    });

    expect(livekit.connect).not.toHaveBeenCalled();
    expect(api.audioCall).toHaveBeenCalledWith("conversation-2");
    expect(screen.getByRole("button", { name: "Start audio call" })).toBeVisible();
  });

  it("disconnects an in-flight connection on unmount and ignores its completion", async () => {
    const api = apiWith(activeCall);
    const connectRequest = deferred<void>();
    livekit.connect.mockReturnValueOnce(connectRequest.promise);
    const user = userEvent.setup();
    const view = render(<AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />);

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    await waitFor(() => expect(livekit.connect).toHaveBeenCalledTimes(1));

    view.unmount();
    expect(livekit.disconnect).toHaveBeenCalledWith(true);
    await act(async () => {
      connectRequest.resolve();
      await connectRequest.promise;
    });

    expect(livekit.startAudio).not.toHaveBeenCalled();
  });

  it("disconnects and removes call media when the tenant capability is disabled", async () => {
    const api = apiWith(activeCall);
    const user = userEvent.setup();
    const view = render(
      <AudioCallPanel api={api} conversation={conversation} enabled currentUserDisplayName="Ada" />
    );

    await user.click(await screen.findByRole("button", { name: "Join audio call" }));
    await user.click(screen.getByRole("button", { name: "Join muted" }));
    expect(await screen.findByText("Connected")).toBeVisible();

    view.rerender(
      <AudioCallPanel
        api={api}
        conversation={conversation}
        enabled={false}
        currentUserDisplayName="Ada"
      />
    );

    await waitFor(() => expect(livekit.disconnect).toHaveBeenCalledWith(true));
    expect(screen.queryByText("Connected")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Audio calls disabled" })).toBeDisabled();
  });
});
