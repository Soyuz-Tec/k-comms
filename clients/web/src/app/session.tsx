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
import { ApiClient, loadStoredSession, storeSession } from "../api";
import { clearDrafts } from "../lib/drafts";
import { isInsecureNonLoopbackOrigin } from "../lib/transportSecurity";
import { rememberWorkspaceSlug } from "../lib/workspacePreference";
import type { Session } from "../types";

const apiBase = import.meta.env.VITE_API_BASE_URL || "";
const transportPolicyRetryDelaysMs = [1_000, 3_000, 10_000] as const;
const transportPolicyRecurringRetryMs = 30_000;

export type SessionUpdate =
  | Session
  | null
  | ((current: Session | null) => Session | null);

interface SessionContextValue {
  api: ApiClient;
  session: Session | null;
  transportPolicyReady: boolean;
  accountActionsAllowed: boolean;
  mediaActionsAllowed: boolean;
  setSession: (update: SessionUpdate) => void;
  logout: () => Promise<void>;
}

const SessionContext = createContext<SessionContextValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const insecureNetworkOrigin = isInsecureNonLoopbackOrigin();
  const [retainedSession, updateRetainedSession] = useState<Session | null>(() =>
    loadMemberSessionForOrigin(insecureNetworkOrigin)
  );
  const retainedSessionRef = useRef(retainedSession);
  const [transportPolicy, updateTransportPolicy] = useState(() => ({
    ready: insecureNetworkOrigin,
    accountActionsAllowed: false,
    mediaActionsAllowed: false
  }));
  const transportPolicyRef = useRef(transportPolicy);
  const session =
    transportPolicy.ready && transportPolicy.accountActionsAllowed
      ? retainedSession
      : null;

  const setSession = useCallback((update: SessionUpdate) => {
    const retainedPrevious = retainedSessionRef.current;
    const policy = transportPolicyRef.current;
    if (!policy.ready) return;
    const previous =
      policy.accountActionsAllowed ? retainedPrevious : null;
    const candidate = typeof update === "function" ? update(previous) : update;
    const next = policy.accountActionsAllowed ? candidate : null;
    if (!next && retainedPrevious) {
      clearDrafts(retainedPrevious.tenant.id, retainedPrevious.user.id);
    }
    retainedSessionRef.current = next;
    if (next) rememberWorkspaceSlug(next.tenant.slug);
    storeSession(next);
    updateRetainedSession(next);
  }, []);

  const apiRef = useRef<ApiClient | null>(null);
  if (!apiRef.current) apiRef.current = new ApiClient(apiBase, session, setSession);
  const api = apiRef.current;
  api.setSession(session);

  useEffect(() => {
    if (insecureNetworkOrigin) return;

    let current = true;
    let resolved = false;
    let inFlight = false;
    let failureCount = 0;
    let retryTimer: number | undefined;

    function retry() {
      if (!current || resolved || retryTimer !== undefined) return;
      const initialDelay = transportPolicyRetryDelaysMs[failureCount - 1];
      retryTimer = window.setTimeout(
        () => {
          retryTimer = undefined;
          check();
        },
        initialDelay ?? transportPolicyRecurringRetryMs
      );
    }

    function check() {
      if (!current || resolved || inFlight) return;
      inFlight = true;
      void api.status().then((status) => {
        inFlight = false;
        if (!current) return;
        const capabilities = status.capabilities;
        if (capabilities?.secure_account_actions === false) {
          resolved = true;
          const deniedPolicy = {
            ready: true,
            accountActionsAllowed: false,
            mediaActionsAllowed: false
          };
          transportPolicyRef.current = deniedPolicy;
          updateTransportPolicy(deniedPolicy);
          setSession(null);
          return;
        }
        if (
          capabilities?.secure_account_actions !== true ||
          typeof capabilities.secure_media_actions !== "boolean"
        ) {
          failureCount += 1;
          retry();
          return;
        }
        resolved = true;
        const allowedPolicy = {
          ready: true,
          accountActionsAllowed: true,
          mediaActionsAllowed: capabilities.secure_media_actions
        };
        transportPolicyRef.current = allowedPolicy;
        updateTransportPolicy(allowedPolicy);
      }).catch(() => {
        inFlight = false;
        if (!current) return;
        failureCount += 1;
        retry();
      });
    }

    function retryWhenOnline() {
      if (!current || resolved || inFlight) return;
      if (retryTimer !== undefined) {
        window.clearTimeout(retryTimer);
        retryTimer = undefined;
      }
      check();
    }

    window.addEventListener("online", retryWhenOnline);
    check();

    return () => {
      current = false;
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      window.removeEventListener("online", retryWhenOnline);
    };
  }, [api, insecureNetworkOrigin, setSession]);

  useEffect(() => {
    if (!session) return;
    const receivedAt = session.received_at || Date.now();
    const lifetime = session.expires_in * 1_000;
    const refreshLead = Math.min(60_000, Math.max(5_000, lifetime * 0.2));
    const delay = Math.max(1_000, receivedAt + lifetime - refreshLead - Date.now());
    const timer = window.setTimeout(() => {
      // A temporary network/provider failure intentionally leaves the session
      // in storage. ApiClient only clears it when refresh is definitively rejected.
      void api.refreshSession().catch(() => undefined);
    }, delay);
    return () => window.clearTimeout(timer);
  }, [api, session]);

  useEffect(() => {
    if (!session) return;
    const refreshWhenOnline = () => {
      const expiresAt = (session.received_at || 0) + session.expires_in * 1_000;
      if (expiresAt - Date.now() < 90_000) void api.refreshSession().catch(() => undefined);
    };
    window.addEventListener("online", refreshWhenOnline);
    return () => window.removeEventListener("online", refreshWhenOnline);
  }, [api, session]);

  const logout = useCallback(async () => {
    try {
      await api.logout();
    } finally {
      setSession(null);
    }
  }, [api, setSession]);

  const value = useMemo(() => ({
    api,
    session,
    transportPolicyReady: transportPolicy.ready,
    accountActionsAllowed: transportPolicy.accountActionsAllowed,
    mediaActionsAllowed: transportPolicy.mediaActionsAllowed,
    setSession,
    logout
  }), [
    api,
    logout,
    session,
    setSession,
    transportPolicy.accountActionsAllowed,
    transportPolicy.mediaActionsAllowed,
    transportPolicy.ready
  ]);
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function loadMemberSessionForOrigin(
  insecureNetworkOrigin: boolean
): Session | null {
  const session = loadStoredSession();
  if (!insecureNetworkOrigin) return session;
  if (session) {
    clearDrafts(session.tenant.id, session.user.id);
    storeSession(null);
  }
  return null;
}

export function useSession(): SessionContextValue {
  const value = useContext(SessionContext);
  if (!value) throw new Error("useSession must be used within SessionProvider");
  return value;
}
