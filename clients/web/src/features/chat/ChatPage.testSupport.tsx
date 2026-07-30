// Shared integration harness; import this module before ChatPage so Vitest
// installs the provider and transport doubles before the component loads.
import { useLocation, useNavigate } from "react-router";
import { vi } from "vitest";
import type {
  Conversation,
  ConversationMembership,
  Message,
  User
} from "../../types";
import type { RealtimeCallbacks } from "../../realtime";

const uploadHarness = vi.hoisted(() => ({
  sha256: vi.fn().mockResolvedValue("checksum"),
  upload: vi.fn().mockResolvedValue(undefined)
}));

vi.mock("../../api", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  sha256: uploadHarness.sha256,
  uploadToPresignedTarget: uploadHarness.upload
}));

vi.mock("../../app/step-up", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useStepUp: () => ({
    runWithStepUp: <T,>(action: () => Promise<T>) => action()
  })
}));

const harness = vi.hoisted(() => ({
  callbacks: null as RealtimeCallbacks | null,
  markRead: vi.fn<(sequence: number) => Promise<unknown>>(),
  sendMessage: vi.fn<(input: unknown) => Promise<Message>>(),
  setError: vi.fn(),
  setConversations: vi.fn(),
  createConversation: vi.fn(),
  startDirectConversation: vi.fn(),
  refreshConversations: vi.fn().mockResolvedValue(undefined),
  launchCall: vi.fn(),
  publishRealtimeEvent: vi.fn(),
  audioCallsAvailable: true,
  videoCallsAvailable: true,
  userRole: "member" as "member" | "owner",
  conversations: [
    {
      id: "conversation-1",
      tenant_id: "tenant-1",
      kind: "channel",
      title: "General",
      counterpart_user_id: null,
      counterpart_display_name: null,
      visibility: "tenant",
      latest_sequence: 1,
      unread_count: 1,
      last_read_sequence: 0,
      version: 1,
      inserted_at: "2026-07-12T10:00:00Z",
      updated_at: "2026-07-12T10:00:00Z"
    }
  ] as Conversation[],
  users: [
    {
      id: "user-1",
      tenant_id: "tenant-1",
      display_name: "Ada",
      email: "ada@example.test",
      role: "member",
      status: "active"
    },
    {
      id: "user-2",
      tenant_id: "tenant-1",
      display_name: "Grace",
      email: "grace@example.test",
      role: "member",
      status: "active"
    }
  ] as User[],
  api: {} as Record<string, ReturnType<typeof vi.fn>>
}));

vi.mock("../calls/CallSessionProvider", () => ({
  useCallSession: () => ({
    launchCall: harness.launchCall,
    publishRealtimeEvent: harness.publishRealtimeEvent
  }),
  CallLaunchActions: ({
    conversation,
    audioEnabled,
    videoEnabled
  }: {
    conversation: Conversation;
    audioEnabled: boolean;
    videoEnabled: boolean;
  }) => (
    <div>
      <button
        type="button"
        disabled={!audioEnabled}
        onClick={() => harness.launchCall(conversation, "audio")}
      >
        {audioEnabled ? "Start audio call" : "Audio calls disabled"}
      </button>
      <button
        type="button"
        disabled={!videoEnabled}
        onClick={() => harness.launchCall(conversation, "video")}
      >
        {videoEnabled ? "Start video call" : "Video calls disabled"}
      </button>
    </div>
  )
}));

vi.mock("../../realtime", () => ({
  socketEndpoint: () => "/socket",
  RealtimeConversation: class {
    constructor(
      _endpoint: string,
      _ticket: string,
      _conversationId: string,
      _after: () => number,
      callbacks: RealtimeCallbacks
    ) {
      harness.callbacks = callbacks;
    }

    connect() {
      harness.callbacks?.onStatus("live");
    }

    disconnect() {
      // Test double.
    }

    markRead(sequence: number) {
      return harness.markRead(sequence);
    }

    sendMessage(input: unknown) {
      return harness.sendMessage(input);
    }

    setTyping() {
      // Test double.
    }
  }
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: harness.api,
    session: {
      access_token: "access",
      refresh_token: "refresh",
      token_type: "Bearer",
      expires_in: 900,
      tenant: {
        id: "tenant-1",
        name: "Acme",
        slug: "acme",
        status: "active"
      },
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        email: "ada@example.test",
        role: harness.userRole,
        status: "active"
      },
      device: {
        id: "device-1",
        user_id: "user-1",
        name: "Browser",
        platform: "web"
      }
    }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    conversations: harness.conversations,
    users: harness.users,
    capabilities: {
      allow_audio_calls: true,
      allow_video_calls: true,
      allow_public_channels: true,
      message_edit_window_seconds: 900,
      max_attachment_bytes: 25_000_000
    },
    audioCallsAvailable: harness.audioCallsAvailable,
    videoCallsAvailable: harness.videoCallsAvailable,
    loading: false,
    setError: harness.setError,
    setConversations: harness.setConversations,
    createConversation: harness.createConversation,
    startDirectConversation: harness.startDirectConversation,
    refreshConversations: harness.refreshConversations
  })
}));

export function message(sequence: number): Message {
  return {
    id: `message-${sequence}`,
    tenant_id: "tenant-1",
    conversation_id: "conversation-1",
    sender_user_id: "user-1",
    sender_device_id: "device-1",
    client_message_id: `client-${sequence}`,
    conversation_sequence: sequence,
    body: `Message ${sequence}`,
    metadata: {},
    status: "active",
    inserted_at: "2026-07-12T10:00:00Z",
    attachments: [],
    reactions: []
  };
}

export function getChatPageHarness() {
  return harness;
}

export function getUploadHarness() {
  return uploadHarness;
}

export function LocationProbe() {
  const location = useLocation();
  return (
    <output aria-label="location-search">
      {`${location.search}${location.hash}`}
    </output>
  );
}

export function membershipFor(user: User): ConversationMembership {
  return {
    id: `membership-${user.id}`,
    role: "member",
    joined_at: "2026-07-12T10:00:00Z",
    last_read_sequence: 0,
    user
  };
}

export function HistoryBack() {
  const navigate = useNavigate();
  return (
    <button type="button" onClick={() => navigate(-1)}>
      Browser back
    </button>
  );
}

export function setMobileViewport(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn().mockImplementation((media: string) => ({
      matches: media === "(max-width: 760px)" ? matches : false,
      media,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(() => true)
    }))
  });
}

export function resetChatPageHarness() {
  setMobileViewport(false);
  Object.defineProperty(document, "visibilityState", {
    configurable: true,
    value: "visible"
  });
  window.localStorage.clear();
  harness.callbacks = null;
  harness.audioCallsAvailable = true;
  harness.videoCallsAvailable = true;
  harness.userRole = "member";
  harness.launchCall.mockReset().mockReturnValue(true);
  harness.publishRealtimeEvent.mockReset();
  harness.conversations = [
    {
      id: "conversation-1",
      tenant_id: "tenant-1",
      kind: "channel",
      title: "General",
      counterpart_user_id: null,
      counterpart_display_name: null,
      visibility: "tenant",
      latest_sequence: 1,
      unread_count: 1,
      last_read_sequence: 0,
      version: 1,
      inserted_at: "2026-07-12T10:00:00Z",
      updated_at: "2026-07-12T10:00:00Z"
    }
  ];
  harness.users = [
    {
      id: "user-1",
      tenant_id: "tenant-1",
      display_name: "Ada",
      email: "ada@example.test",
      role: "member",
      status: "active"
    },
    {
      id: "user-2",
      tenant_id: "tenant-1",
      display_name: "Grace",
      email: "grace@example.test",
      role: "member",
      status: "active"
    }
  ];
  harness.createConversation.mockReset();
  harness.startDirectConversation.mockReset();
  harness.markRead.mockReset().mockResolvedValue({});
  harness.sendMessage.mockReset().mockResolvedValue(message(2));
  uploadHarness.sha256.mockReset().mockResolvedValue("checksum");
  uploadHarness.upload.mockReset().mockResolvedValue(undefined);
  Object.assign(harness.api, {
    socketTicket: vi
      .fn()
      .mockResolvedValue({ ticket: "one-time-ticket", expires_in: 60 }),
    audioCall: vi.fn().mockResolvedValue(null),
    startAudioCall: vi.fn(),
    joinAudioCall: vi.fn(),
    endAudioCall: vi.fn(),
    messages: vi.fn().mockResolvedValue({
      data: [message(1)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    }),
    messageSenderLabels: vi.fn().mockResolvedValue([]),
    conversationMembers: vi.fn().mockResolvedValue([
      {
        id: "membership-current",
        role: "member",
        joined_at: "2026-07-12T10:00:00Z",
        last_read_sequence: 0,
        user: {
          id: "user-1",
          tenant_id: "tenant-1",
          display_name: "Ada",
          account_type: "human",
          role: "member",
          status: "active"
        }
      },
      {
        id: "membership-human",
        role: "member",
        joined_at: "2026-07-12T10:00:00Z",
        last_read_sequence: 0,
        user: {
          id: "user-2",
          tenant_id: "tenant-1",
          display_name: "Grace",
          account_type: "human",
          role: "member",
          status: "active"
        }
      },
      {
        id: "membership-service",
        role: "member",
        joined_at: "2026-07-12T10:00:00Z",
        last_read_sequence: 0,
        user: {
          id: "service-1",
          tenant_id: "tenant-1",
          display_name: "Build bot",
          account_type: "service",
          role: "member",
          status: "active"
        }
      }
    ]),
    discoverPublicChannels: vi.fn().mockResolvedValue({
      data: [],
      page: { limit: 25, has_more: false, next_cursor: null }
    }),
    searchMessagePage: vi.fn().mockResolvedValue({
      data: [],
      page: { limit: 25, has_more: false, next_cursor: null }
    }),
    createModerationCase: vi.fn().mockResolvedValue({ id: "case-1" }),
    messageThread: vi.fn().mockResolvedValue({
      data: { root: message(1), replies: [], reply_count: 0 },
      page: {
        has_more: false,
        next_before_sequence: null
      }
    }),
    abandonAttachment: vi.fn().mockResolvedValue(undefined)
  });
}
