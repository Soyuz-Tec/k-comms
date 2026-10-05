import { useCallback, useEffect, useRef, useState } from "react";
import { useSession } from "../../app/session";
import { ApiError } from "../../api/errors";
import { errorText } from "../../lib/format";
import type { MemberWorkspace, MemberWorkspaceInput, OnboardingAction } from "../../types";

const changedEvent = "k-comms:member-workspace-changed";
export function announceMemberWorkspaceChange() {
  window.dispatchEvent(new Event(changedEvent));
}

export function isPrivateAccessDenied(reason: unknown) {
  return reason instanceof ApiError && [401, 403, 404].includes(reason.status);
}

export function useMemberWorkspace() {
  const { api, session } = useSession();
  const scope = session ? `${session.tenant.id}:${session.user.id}:${session.device?.id || ""}` : "";
  const authority = session?.access_token || "";
  const identityRef = useRef({ scope, authority, serial: 0 });
  const generation = useRef(0);
  const busyRef = useRef(false);
  const deferredRefresh = useRef(false);
  if (identityRef.current.scope !== scope || identityRef.current.authority !== authority) {
    identityRef.current = { scope, authority, serial: identityRef.current.serial + 1 };
    generation.current += 1;
    busyRef.current = false;
  }
  const identity = identityRef.current.serial;
  const [state, setState] = useState<{ identity: number; data: MemberWorkspace | null }>({ identity, data: null });
  const dataRef = useRef<MemberWorkspace | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [denied, setDenied] = useState(false);
  const [pendingOnboarding, setPendingOnboarding] = useState<OnboardingAction | null>(null);
  const data = state.identity === identity ? state.data : null;

  const refresh = useCallback(async (duringMutation = false): Promise<MemberWorkspace | null> => {
    if (busyRef.current && !duringMutation) { deferredRefresh.current = true; return null; }
    const request = ++generation.current;
    if (!scope) return null;
    setLoading(true);
    setError(null);
    try {
      const value = await api.memberWorkspace();
      if (request !== generation.current || identity !== identityRef.current.serial) return null;
      dataRef.current = value;
      setState({ identity, data: value });
      setDenied(false);
      return value;
    } catch (reason: unknown) {
      if (request !== generation.current || identity !== identityRef.current.serial) return null;
      if (isPrivateAccessDenied(reason)) {
        dataRef.current = null;
        setState({ identity, data: null });
        setDenied(true);
        setPendingOnboarding(null);
      }
      setError(errorText(reason));
      return null;
    } finally {
      if (request === generation.current && identity === identityRef.current.serial) setLoading(false);
    }
  }, [api, identity, scope]);

  useEffect(() => {
    dataRef.current = null;
    setState({ identity, data: null });
    setDenied(false);
    setBusy(false);
    setPendingOnboarding(null);
    void refresh();
    const reloadVisible = () => { if (document.visibilityState !== "hidden") void refresh(); };
    window.addEventListener("focus", reloadVisible);
    document.addEventListener("visibilitychange", reloadVisible);
    window.addEventListener(changedEvent, reloadVisible);
    return () => {
      generation.current += 1;
      window.removeEventListener("focus", reloadVisible);
      document.removeEventListener("visibilitychange", reloadVisible);
      window.removeEventListener(changedEvent, reloadVisible);
    };
  }, [identity, refresh]);

  async function mutate(operation: () => Promise<MemberWorkspace>) {
    const request = ++generation.current;
    busyRef.current = true;
    setBusy(true);
    setError(null);
    try {
      const value = await operation();
      if (request !== generation.current || identity !== identityRef.current.serial) return false;
      dataRef.current = value;
      setState({ identity, data: value });
      setDenied(false);
      return true;
    } catch (reason: unknown) {
      if (request !== generation.current || identity !== identityRef.current.serial) return false;
      if (isPrivateAccessDenied(reason)) {
        dataRef.current = null;
        setState({ identity, data: null });
        setDenied(true);
        setPendingOnboarding(null);
      } else if (reason instanceof ApiError && reason.status === 409) {
        const fresh = await refresh(true);
        if (identity !== identityRef.current.serial) return false;
        if (fresh) setError("Your workspace changed elsewhere. Your pending changes are kept; review and retry.");
      } else {
        setError(errorText(reason));
      }
      return false;
    } finally {
      if (identity === identityRef.current.serial) {
        busyRef.current = false;
        setBusy(false);
        if (deferredRefresh.current) { deferredRefresh.current = false; void refresh(); }
      }
    }
  }

  async function replace(input: Omit<MemberWorkspaceInput, "version">) {
    const current = dataRef.current;
    if (!current || denied || busyRef.current) return false;
    return mutate(() => api.updateMemberWorkspace({ ...input, version: current.version }));
  }

  async function onboarding(action: OnboardingAction) {
    const current = dataRef.current;
    if (!current || denied || busyRef.current) return false;
    setPendingOnboarding(action);
    const success = await mutate(() => api.updateOnboarding({ version: current.version, action }));
    if (success && identity === identityRef.current.serial) setPendingOnboarding(null);
    return success;
  }

  function denyAccess() {
    generation.current += 1;
    dataRef.current = null;
    setState({ identity, data: null });
    setDenied(true);
    setPendingOnboarding(null);
    setError("Your private workspace is unavailable. Sign in again to continue.");
  }

  return {
    data, identity, loading, busy: state.identity === identity && busy,
    error: state.identity === identity ? error : null,
    denied: state.identity === identity && denied,
    pendingOnboarding: state.identity === identity ? pendingOnboarding : null,
    refresh, replace, onboarding, denyAccess
  };
}
