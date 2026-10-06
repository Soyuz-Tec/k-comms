import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { ReactNode } from "react";
import type { CreateConversationInput } from "../api";
import type { Conversation, ServiceStatus, User, UserCapabilities } from "../types";
import { errorText } from "../lib/format";
import { RealtimeInbox, socketEndpoint } from "../realtime";
import { useSession } from "./session";
import { useFederationAuthorityGeneration } from "../features/federation/useFederationAuthorityGeneration";

interface WorkspaceDataValue {
  conversations: Conversation[];
  users: User[];
  capabilities: UserCapabilities | null;
  /**
   * The last successful /api/v1/status payload, kept whole rather than
   * reduced to the two call booleans. Feature switches that have both a
   * deployment half and a tenant half -- immersive mode is the first -- need
   * to read the service capabilities directly, and re-fetching status per
   * consumer would multiply a request the workspace already polls.
   */
  serviceStatus: ServiceStatus | null;
  audioCallsAvailable: boolean;
  videoCallsAvailable: boolean;
  loading: boolean;
  error: string | null;
  setError: (error: string | null) => void;
  setConversations: React.Dispatch<React.SetStateAction<Conversation[]>>;
  setUsers: React.Dispatch<React.SetStateAction<User[]>>;
  setCapabilities: React.Dispatch<React.SetStateAction<UserCapabilities | null>>;
  refreshAll: () => Promise<void>;
  refreshCallAvailability: () => Promise<void>;
  refreshConversations: () => Promise<void>;
  updateConversationFavorite: (id: string, favorite: boolean) => Promise<void>;
  createConversation: (input: CreateConversationInput) => Promise<Conversation>;
  startDirectConversation: (userId: string) => Promise<Conversation>;
}

const WorkspaceDataContext = createContext<WorkspaceDataValue | null>(null);

export function WorkspaceDataProvider({ children }: { children: ReactNode }) {
  const { api, session, setSession } = useSession();
  const authority = useFederationAuthorityGeneration(session);
  const ownerRef = useRef({ api, authority, request: 0, membership: 0 });
  if (ownerRef.current.api !== api || ownerRef.current.authority !== authority) {
    ownerRef.current = { api, authority, request: 0, membership: 0 };
  }
  const owner = ownerRef.current;
  const [conversationState, setConversationState] = useState({ owner, rows: [] as Conversation[] });
  const conversations = conversationState.owner === owner ? conversationState.rows : [];
  const setConversations = useCallback<React.Dispatch<React.SetStateAction<Conversation[]>>>((update) => {
    if (ownerRef.current !== owner) return;
    // A local cursor, membership or message change supersedes any older list snapshot.
    owner.request += 1;
    setConversationState(previous => {
      if (ownerRef.current !== owner) return previous;
      const rows = previous.owner === owner ? previous.rows : [];
      return { owner, rows: typeof update === "function" ? update(rows) : update };
    });
  }, [authority, owner]);
  const [users, setUsers] = useState<User[]>([]);
  const [capabilities, setCapabilities] = useState<UserCapabilities | null>(null);
  const [serviceStatus, setServiceStatus] = useState<ServiceStatus | null>(null);
  const [audioCallsAvailable, setAudioCallsAvailable] = useState(false);
  const [videoCallsAvailable, setVideoCallsAvailable] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refreshConversations = useCallback(async () => {
    const request = ++owner.request;
    try {
      const available = await api.conversations();
      if (ownerRef.current === owner && owner.request === request) setConversations(available);
    } catch (reason) {
      if (ownerRef.current === owner && owner.request === request) {
        setConversations(rows => rows.map(row => ({ ...row, inbox: null })));
      }
      throw reason;
    }
  }, [api, owner, setConversations]);

  const updateConversationFavorite = useCallback(async (id: string, favorite: boolean) => {
    // Invalidate earlier list snapshots before and after the write, so a slow
    // poll cannot reverse a successful preference change.
    owner.request += 1;
    const result = await api.setConversationFavorite(id, favorite);
    if (ownerRef.current !== owner) return;
    owner.request += 1;
    setConversations(rows => rows.map(row => row.id === id ? { ...row, favorite: result.favorite } : row));
  }, [api, owner, setConversations]);

  const refreshCallAvailability = useCallback(async () => {
    try {
      const nextStatus = await api.status();
      setServiceStatus(nextStatus);
      setAudioCallsAvailable(nextStatus.capabilities?.audio_calls === true);
      setVideoCallsAvailable(nextStatus.capabilities?.video_calls === true);
    } catch {
      // Preserve the last known readiness when the status request fails transiently.
    }
  }, [api]);

  const refreshAll = useCallback(async () => {
    if (!session) return;
    setError(null);
    const request = ++owner.request;
    try {
      const [identity, tenantUsers, available] = await Promise.all([
        api.me(),
        api.users(),
        api.conversations(),
        refreshCallAvailability()
      ]);
      if (ownerRef.current !== owner) return;
      setSession({
        ...session,
        tenant: identity.tenant,
        user: identity.user,
        device: identity.device
      });
      setUsers(tenantUsers);
      if (owner.request === request) setConversations(available);
      setCapabilities(identity.capabilities);
    } catch (reason: unknown) {
      if (ownerRef.current === owner) {
        setError(errorText(reason));
        if (owner.request === request) setConversations(rows => rows.map(row => ({ ...row, inbox: null })));
      }
    } finally {
      if (ownerRef.current === owner) setLoading(false);
    }
  }, [api, owner, refreshCallAvailability, session?.access_token, setConversations, setSession]);

  useEffect(() => {
    void refreshAll();
  }, [refreshAll]);

  useEffect(() => {
    const refreshIfVisible = () => {
      if (document.visibilityState !== "visible") return;
      void Promise.allSettled([
        refreshConversations(),
        refreshCallAvailability()
      ]);
    };
    const timer = window.setInterval(refreshIfVisible, 15_000);
    window.addEventListener("focus", refreshIfVisible);
    document.addEventListener("visibilitychange", refreshIfVisible);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refreshIfVisible);
      document.removeEventListener("visibilitychange", refreshIfVisible);
    };
  }, [refreshCallAvailability, refreshConversations]);

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
          if (ownerRef.current !== owner) return;
          owner.request += 1;
          setConversations((current) => current.map((conversation) => {
            if (conversation.id !== event.conversation_id) return conversation;
            const latest = Math.max(conversation.latest_sequence, event.latest_sequence);
            return {
              ...conversation,
              latest_sequence: latest,
              inbox: null,
              unread_count: Math.max(conversation.unread_count || 0, latest - (conversation.last_read_sequence || 0))
            };
          }));
          scheduleRefresh();
        },
        onMembership: (event) => {
          if (ownerRef.current !== owner) return;
          owner.membership += 1;
          owner.request += 1;
          setConversations(rows => rows.filter(row => event.action !== "removed" || row.id !== event.conversation_id)
            .map(row => ({ ...row, inbox: null })));
          scheduleRefresh();
        },
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
  }, [api, owner, refreshConversations, session?.user.id, setConversations]);

  const createConversation = useCallback(
    async (input: CreateConversationInput) => {
      const conversation = await api.createConversation(input);
      setConversations((current) => [conversation, ...current.filter(({ id }) => id !== conversation.id)]);
      return conversation;
    },
    [api, setConversations]
  );

  const startDirectConversation = useCallback(
    async (userId: string) => {
      const membership = owner.membership;
      const response = await api.directConversation(userId);
      if (ownerRef.current !== owner || owner.membership !== membership) {
        throw new Error("Conversation access changed. Try again.");
      }
      const conversation = response.data;
      setConversations((current) => {
        const previous = current.find(({ id }) => id === conversation.id);
        // Direct admission returns conversation metadata without the user's
        // list-only favorite/read state. Preserve current preferences, while
        // dropping cached excerpts if the returned timeline or mode changed.
        const merged = { ...previous, ...conversation };
        if (previous && (previous.latest_sequence !== conversation.latest_sequence ||
          (previous.content_mode ?? "server_readable") !== (conversation.content_mode ?? "server_readable") ||
          conversation.archived_at)) merged.inbox = null;
        return [merged, ...current.filter(({ id }) => id !== conversation.id)];
      });
      return conversation;
    },
    [api, owner, setConversations]
  );

  const value = useMemo(
    () => ({
      conversations,
      users,
      capabilities,
      serviceStatus,
      audioCallsAvailable,
      videoCallsAvailable,
      loading,
      error,
      setError,
      setConversations,
      setUsers,
      setCapabilities,
      refreshAll,
      refreshCallAvailability,
      refreshConversations,
      updateConversationFavorite,
      createConversation,
      startDirectConversation
    }),
    [
      conversations,
      capabilities,
      serviceStatus,
      audioCallsAvailable,
      videoCallsAvailable,
      createConversation,
      error,
      loading,
      refreshAll,
      refreshCallAvailability,
      refreshConversations,
      updateConversationFavorite,
      setConversations,
      startDirectConversation,
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

export function useOptionalWorkspaceData(): WorkspaceDataValue | null {
  return useContext(WorkspaceDataContext);
}
