import { useCallback, useEffect, useRef, useState } from "react";
import { useSession } from "../../app/session";
import { errorText } from "../../lib/format";
import type { Availability, UpdateAvailability } from "../../types/enterpriseIdentity";

const changedEvent = "k-comms:availability-changed";
const changedStorageKey = "k-comms.availability-changed.v1";
const offlineError = "You are offline. Reconnect to check or change availability.";
const accessDenied = (reason: unknown) => Boolean(reason && typeof reason === "object" && "status" in reason && [401, 403, 404].includes(Number(reason.status)));

function announceChange() {
  window.dispatchEvent(new Event(changedEvent));
  // Invalidation only: another tab must fetch under its own current authority.
  try { window.localStorage.setItem(changedStorageKey, String(Date.now())); } catch { /* Focus refresh remains available. */ }
}

export function useAvailability() {
  const { api, session } = useSession();
  const scope = session ? JSON.stringify([
    session.tenant.id, session.tenant.status, session.user.id, session.user.tenant_id,
    session.user.status, session.user.role, session.user.version, session.user.account_type,
    session.user.access_scope, session.device.id, session.device.user_id, session.device.revoked_at,
    session.access_token, session.refresh_token
  ]) : "";
  const identity = useRef({ scope, api, serial: 0 });
  const request = useRef(0);
  const busyRef = useRef(false);
  if (identity.current.scope !== scope || identity.current.api !== api) {
    identity.current = { scope, api, serial: identity.current.serial + 1 };
    request.current += 1;
    busyRef.current = false;
  }
  const generation = identity.current.serial;
  const supported = Boolean(scope && typeof api?.availability === "function");
  const [state, setState] = useState({ generation, data: null as Availability | null, loading: true, busy: false, error: "" });
  const [denied, setDenied] = useState(false);
  const current = state.generation === generation ? state : { generation, data: null, loading: true, busy: false, error: "" };

  const refresh = useCallback(async () => {
    if (!supported || busyRef.current) return;
    const serial = ++request.current;
    if (!navigator.onLine) {
      setState({ generation, data: null, loading: false, busy: false, error: offlineError });
      return;
    }
    try {
      const data = await api.availability();
      if (serial === request.current && generation === identity.current.serial) {
        setDenied(false);
        setState({ generation, data, loading: false, busy: false, error: "" });
      }
    } catch (reason) {
      if (serial === request.current && generation === identity.current.serial) {
        // Never present retained status as current when authority or connectivity is lost.
        setDenied(accessDenied(reason));
        setState({ generation, data: null, loading: false, busy: false, error: errorText(reason) });
      }
    }
  }, [api, generation, supported]);

  useEffect(() => {
    setState({ generation, data: null, loading: supported, busy: false, error: "" });
    setDenied(false);
    void refresh();
    const visible = () => { if (document.visibilityState !== "hidden") void refresh(); };
    const stored = (event: StorageEvent) => { if (event.key === changedStorageKey) visible(); };
    const offline = () => {
      request.current += 1;
      busyRef.current = false;
      setState({ generation, data: null, loading: false, busy: false, error: offlineError });
    };
    window.addEventListener("focus", visible);
    window.addEventListener("online", visible);
    window.addEventListener("offline", offline);
    window.addEventListener("storage", stored);
    window.addEventListener(changedEvent, visible);
    document.addEventListener("visibilitychange", visible);
    // Availability has no socket event. Refresh visible sessions so another
    // device's updates and weekly schedule boundaries do not stay stale.
    const timer = supported ? window.setInterval(visible, 60_000) : undefined;
    return () => {
      request.current += 1;
      window.clearInterval(timer);
      window.removeEventListener("focus", visible);
      window.removeEventListener("online", visible);
      window.removeEventListener("offline", offline);
      window.removeEventListener("storage", stored);
      window.removeEventListener(changedEvent, visible);
      document.removeEventListener("visibilitychange", visible);
    };
  }, [generation, refresh, supported]);

  useEffect(() => {
    const deadlines = [current.data?.presence_expires_at, current.data?.dnd_until, current.data?.retry_at]
      .map((value) => value ? Date.parse(value) - Date.now() : 0).filter((value) => value > 0);
    if (!deadlines.length) return;
    const timer = window.setTimeout(() => void refresh(), Math.min(Math.min(...deadlines) + 50, 2_147_483_647));
    return () => window.clearTimeout(timer);
  }, [current.data, refresh]);

  async function save(input: UpdateAvailability | ((fresh: Availability) => UpdateAvailability)) {
    if (!supported || busyRef.current) return null;
    if (!navigator.onLine) { void refresh(); return null; }
    const serial = ++request.current;
    busyRef.current = true;
    setState((previous) => ({ ...previous, generation, busy: true, error: "" }));
    const valid = () => serial === request.current && generation === identity.current.serial;
    try {
      // Quick status changes preserve the latest saved weekly policy, including
      // changes made in a different session since this menu was opened.
      const update = typeof input === "function" ? input(await api.availability()) : input;
      if (!valid()) return null;
      const data = await api.updateAvailability(update);
      if (!valid()) return null;
      setDenied(false);
      setState({ generation, data, loading: false, busy: false, error: "" });
      announceChange();
      return data;
    } catch (reason) {
      if (valid()) {
        const denied = accessDenied(reason);
        setDenied(denied);
        setState((previous) => ({ ...previous, data: denied ? null : previous.data, busy: false, error: errorText(reason) }));
      }
      return null;
    } finally {
      if (valid()) busyRef.current = false;
    }
  }

  return { ...current, denied: state.generation === generation && denied, supported, refresh, save };
}

export type AvailabilityController = ReturnType<typeof useAvailability>;
export const availabilityLabels: Record<Availability["status"], string> = {
  available: "Available", away: "Away", busy: "Busy", dnd: "Do not disturb", offline: "Appear offline"
};
