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
import type { Session } from "../types";

const apiBase = import.meta.env.VITE_API_BASE_URL || "";

interface SessionContextValue {
  api: ApiClient;
  session: Session | null;
  setSession: (session: Session | null) => void;
  logout: () => Promise<void>;
}

const SessionContext = createContext<SessionContextValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, updateSession] = useState<Session | null>(() => loadStoredSession());
  const sessionRef = useRef(session);

  const setSession = useCallback((next: Session | null) => {
    const previous = sessionRef.current;
    if (!next && previous) clearDrafts(previous.tenant.id, previous.user.id);
    sessionRef.current = next;
    storeSession(next);
    updateSession(next);
  }, []);

  const apiRef = useRef<ApiClient | null>(null);
  if (!apiRef.current) apiRef.current = new ApiClient(apiBase, session, setSession);
  const api = apiRef.current;
  api.setSession(session);

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

  const value = useMemo(() => ({ api, session, setSession, logout }), [api, logout, session, setSession]);
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionContextValue {
  const value = useContext(SessionContext);
  if (!value) throw new Error("useSession must be used within SessionProvider");
  return value;
}
