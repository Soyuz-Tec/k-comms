import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState
} from "react";
import type { ReactNode } from "react";
import type { CreateConversationInput } from "../api";
import type { Conversation, User, UserCapabilities } from "../types";
import { errorText } from "../lib/format";
import { RealtimeInbox, socketEndpoint } from "../realtime";
import { useSession } from "./session";

interface WorkspaceDataValue {
  conversations: Conversation[];
  users: User[];
  capabilities: UserCapabilities | null;
  audioCallsAvailable: boolean;
  videoCallsAvailable: boolean;
  loading: boolean;
  error: string | null;
  setError: (error: string | null) => void;
  setConversations: React.Dispatch<React.SetStateAction<Conversation[]>>;
  setUsers: React.Dispatch<React.SetStateAction<User[]>>;
  setCapabilities: React.Dispatch<React.SetStateAction<UserCapabilities | null>>;
  refreshAll: () => Promise<void>;
  refreshConversations: () => Promise<void>;
  createConversation: (input: CreateConversationInput) => Promise<Conversation>;
}

const WorkspaceDataContext = createContext<WorkspaceDataValue | null>(null);

export function WorkspaceDataProvider({ children }: { children: ReactNode }) {
  const { api, session, setSession } = useSession();
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [capabilities, setCapabilities] = useState<UserCapabilities | null>(null);
  const [audioCallsAvailable, setAudioCallsAvailable] = useState(false);
  const [videoCallsAvailable, setVideoCallsAvailable] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refreshConversations = useCallback(async () => {
    const available = await api.conversations();
    setConversations(available);
  }, [api]);

  const refreshAll = useCallback(async () => {
    if (!session) return;
    setError(null);
    try {
      const [identity, tenantUsers, available, serviceStatus] = await Promise.all([
        api.me(),
        api.users(),
        api.conversations(),
        api.status().catch(() => null)
      ]);
      setSession({
        ...session,
        tenant: identity.tenant,
        user: identity.user,
        device: identity.device
      });
      setUsers(tenantUsers);
      setConversations(available);
      setCapabilities(identity.capabilities);
      setAudioCallsAvailable(serviceStatus?.capabilities?.audio_calls === true);
      setVideoCallsAvailable(serviceStatus?.capabilities?.video_calls === true);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setLoading(false);
    }
  }, [api, session?.access_token, setSession]);

  useEffect(() => {
    void refreshAll();
  }, [refreshAll]);

  useEffect(() => {
    const refreshIfVisible = () => {
      if (document.visibilityState === "visible") void refreshConversations().catch(() => undefined);
    };
    const timer = window.setInterval(refreshIfVisible, 15_000);
    window.addEventListener("focus", refreshIfVisible);
    document.addEventListener("visibilitychange", refreshIfVisible);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refreshIfVisible);
      document.removeEventListener("visibilitychange", refreshIfVisible);
    };
  }, [refreshConversations]);

  useEffect(() => {
    if (!session?.user.id || import.meta.env.VITE_DISABLE_REALTIME === "true") return;
    const userId = session.user.id;
    let refreshTimer: number | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempts = 0;
    let current = true;
    let inbox: RealtimeInbox | null = null;
    const scheduleRefresh = () => {
      if (refreshTimer) window.clearTimeout(refreshTimer);
      refreshTimer = window.setTimeout(() => void refreshConversations().catch(() => undefined), 350);
    };
    const scheduleReconnect = () => {
      if (!current || reconnectTimer) return;
      inbox?.disconnect();
      inbox = null;
      const delay = [1_000, 2_000, 5_000, 10_000][reconnectAttempts] ?? 15_000;
      reconnectAttempts += 1;
      reconnectTimer = window.setTimeout(() => {
        reconnectTimer = null;
        void connectInbox();
      }, delay);
    };

    async function connectInbox() {
      try {
        const { ticket } = await api.socketTicket();
        if (!current) return;
        inbox = new RealtimeInbox(
          socketEndpoint(import.meta.env.VITE_API_BASE_URL || ""),
          ticket,
          userId,
          {
        onConnected: () => { reconnectAttempts = 0; },
        onActivity: (event) => {
          setConversations((current) => current.map((conversation) => {
            if (conversation.id !== event.conversation_id) return conversation;
            const latest = Math.max(conversation.latest_sequence, event.latest_sequence);
            return {
              ...conversation,
              latest_sequence: latest,
              unread_count: Math.max(conversation.unread_count || 0, latest - (conversation.last_read_sequence || 0))
            };
          }));
          scheduleRefresh();
        },
        onMembership: scheduleRefresh,
        onNotification: (event) => {
          window.dispatchEvent(
            new CustomEvent("k-comms:notification-available", { detail: event })
          );
        },
        onError: () => undefined,
        onReconnectRequired: scheduleReconnect
          }
        );
        inbox.connect();
      } catch {
        scheduleReconnect();
      }
    }

    void connectInbox();
    return () => {
      current = false;
      if (refreshTimer) window.clearTimeout(refreshTimer);
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      inbox?.disconnect();
    };
  }, [api, refreshConversations, session?.user.id]);

  const createConversation = useCallback(
    async (input: CreateConversationInput) => {
      const conversation = await api.createConversation(input);
      setConversations((current) => [conversation, ...current.filter(({ id }) => id !== conversation.id)]);
      return conversation;
    },
    [api]
  );

  const value = useMemo(
    () => ({
      conversations,
      users,
      capabilities,
      audioCallsAvailable,
      videoCallsAvailable,
      loading,
      error,
      setError,
      setConversations,
      setUsers,
      setCapabilities,
      refreshAll,
      refreshConversations,
      createConversation
    }),
    [
      conversations,
      capabilities,
      audioCallsAvailable,
      videoCallsAvailable,
      createConversation,
      error,
      loading,
      refreshAll,
      refreshConversations,
      users
    ]
  );

  return <WorkspaceDataContext.Provider value={value}>{children}</WorkspaceDataContext.Provider>;
}

export function useWorkspaceData(): WorkspaceDataValue {
  const value = useContext(WorkspaceDataContext);
  if (!value) throw new Error("useWorkspaceData must be used within WorkspaceDataProvider");
  return value;
}
