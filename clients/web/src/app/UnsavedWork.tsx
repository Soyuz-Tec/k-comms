import { createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useReducer, useRef, type ReactNode } from "react";
import { useBlocker, type BlockerFunction } from "react-router";
import { ConfirmDialog } from "../components/ActionDialog";
import { useSession } from "./session";

type Work = { pending: () => boolean; discard: () => void; description: string; authority: unknown };
type Registry = { authority: unknown; entries: Set<Work>; notify: () => void };
const UnsavedWorkContext = createContext<Registry | null>(null);

/** Opaque, memory-only scope. Authority changes must clear work, never block logout. */
export function useWorkAuthority() {
  const { api, session } = useSession();
  return useMemo(() => session ? {} : null, [api,
    session?.access_token, session?.refresh_token,
    session?.tenant?.id, session?.tenant?.status,
    session?.user?.id, session?.user?.tenant_id, session?.user?.role,
    session?.user?.status, session?.user?.version, session?.user?.account_type,
    session?.user?.access_scope, session?.user?.platform_role, session?.user?.platform_role_expires_at,
    session?.device?.id, session?.device?.user_id, session?.device?.revoked_at
  ]);
}

/** One supported router blocker covers links, programmatic moves and browser history. */
export function UnsavedWorkProvider({ children, authority }: { children: ReactNode; authority: unknown }) {
  const entries = useRef(new Set<Work>()).current;
  const [, notify] = useReducer(value => value + 1, 0);
  const currentAuthority = useRef(authority);
  currentAuthority.current = authority;
  const pendingWork = useCallback(() => [...entries].filter(work => currentAuthority.current !== null && work.authority === currentAuthority.current && work.pending()), [entries]);
  const shouldBlock = useCallback<BlockerFunction>(({ currentLocation, nextLocation }) => {
    // A fragment jump inside the same resource never unmounts its editor.
    if (currentLocation.pathname === nextLocation.pathname && currentLocation.search === nextLocation.search) return false;
    return pendingWork().length > 0;
  }, [pendingWork]);
  const blocker = useBlocker(shouldBlock);
  const registry = useMemo(() => ({ entries, authority, notify }), [entries, authority]);
  const work = blocker.state === "blocked" ? pendingWork() : [];
  useEffect(() => {
    // Authority withdrawal or a confirmed save must never leave a stale dialog.
    if (blocker.state === "blocked" && pendingWork().length === 0) blocker.reset();
  }, [blocker, authority, pendingWork]);
  return <UnsavedWorkContext value={registry}>{children}{blocker.state === "blocked" && work.length > 0 && <ConfirmDialog
    title="Leave unfinished work?"
    description={[...new Set(work.map(item => item.description))].join(" ")}
    impact="Leaving clears this tab's unfinished work. Already submitted actions may still complete on the server. Stay to finish or confirm their result."
    cancelLabel="Stay here" confirmLabel="Leave and discard" tone="danger"
    onCancel={() => blocker.reset()} onConfirm={() => { pendingWork().forEach(item => item.discard()); blocker.proceed(); }}
  />}</UnsavedWorkContext>;
}

/** Drafts and secrets remain with their owning component, never in the registry. */
export function useUnsavedWork(pending: boolean | (() => boolean), description: string, onDiscard?: () => void) {
  const registry = useContext(UnsavedWorkContext);
  const latest = useRef(pending);
  latest.current = pending;
  const discard = useRef(onDiscard);
  discard.current = onDiscard;
  const hasPendingWork = typeof pending === "function" ? pending() : pending;
  useLayoutEffect(() => { registry?.notify(); }, [registry, hasPendingWork]);
  useLayoutEffect(() => {
    const hasWork = () => typeof latest.current === "function" ? latest.current() : latest.current;
    const work = { pending: hasWork, discard: () => discard.current?.(), description, authority: registry?.authority };
    registry?.entries.add(work);
    const warn = (event: BeforeUnloadEvent) => {
      if (hasWork()) { event.preventDefault(); event.returnValue = ""; }
    };
    window.addEventListener("beforeunload", warn);
    return () => { registry?.entries.delete(work); window.removeEventListener("beforeunload", warn); };
  }, [registry, description]);
}
