import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../../api/errors";
import { useSession } from "../../app/session";
import { errorText, formatDateTime } from "../../lib/format";
import type { AgentQueueState, AgentQueueStatus } from "./ivrTypes";

const labels: Record<AgentQueueStatus, string> = { ready: "Ready", away: "Away", wrap_up: "Wrap up" };

export function AgentQueuePanel() {
  const { api } = useSession();
  const [state, setState] = useState<AgentQueueState | null>(null);
  const [unassigned, setUnassigned] = useState(false);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [duration, setDuration] = useState(300);
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(false);
  const generation = useRef(0);
  const load = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true); setError(null);
    try {
      const value = await api.phoneAgentState();
      if (current !== generation.current) return;
      setState(value); setUnassigned(false); setStale(false);
    } catch (reason) {
      if (current !== generation.current) return;
      if (reason instanceof ApiError && reason.code === "telephony_agent_not_assigned") { setUnassigned(true); setState(null); }
      else setError(errorText(reason));
    } finally { if (current === generation.current) setLoading(false); }
  }, [api]);
  useEffect(() => { setState(null); setUnassigned(false); setBusy(false); void load(); return () => { generation.current += 1; }; }, [load]);
  useEffect(() => {
    if (!state?.explicit || !state.expires_at || busy || loading || stale) return;
    const delay = Date.parse(state.expires_at) - Date.now();
    const timeout = window.setTimeout(() => void load(), Math.max(0, Math.min(delay + 100, 3_600_100)));
    return () => window.clearTimeout(timeout);
  }, [state, load, busy, loading, stale]);
  async function setStatus(status: AgentQueueStatus) {
    if (!state || stale || loading) return;
    const current = generation.current;
    setBusy(true); setError(null);
    try {
      const value = await api.setPhoneAgentState({ state: status, duration_seconds: duration, version: state.version });
      if (current === generation.current) setState(value);
    } catch (reason) {
      if (current !== generation.current) return;
      if (reason instanceof ApiError && reason.code === "stale_version") { setStale(true); setError("Your queue state changed elsewhere. Refresh it before choosing another state."); }
      else if (reason instanceof ApiError && reason.code === "telephony_agent_not_assigned") { setState(null); setUnassigned(true); }
      else setError(errorText(reason));
    } finally { if (current === generation.current) setBusy(false); }
  }
  if (unassigned) return null;
  return <section className="phone-agent-state" aria-labelledby="phone-agent-state-heading">
    <header><h2 id="phone-agent-state-heading">Your queue availability</h2><button className="button ghost" type="button" disabled={busy || loading} onClick={() => void load()}>Refresh queue availability</button></header>
    <p>Away and Wrap up pause new queue offers. Your workspace membership, do-not-disturb setting, and active calls still determine eligibility.</p>
    {loading && <p role="status">Loading queue availability…</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    {state && <>
      <p role="status">Queue state: <strong>{labels[state.state]}</strong>{state.explicit && state.expires_at ? ` until ${formatDateTime(state.expires_at)}` : " (default)"}.</p>
      <p>This setting does not confirm that you are online. When it expires, normal routing eligibility resumes.</p>
      <label className="field">Queue state duration<select value={duration} disabled={busy || loading} onChange={event => setDuration(Number(event.currentTarget.value))}><option value={60}>1 minute</option><option value={300}>5 minutes</option><option value={900}>15 minutes</option><option value={1800}>30 minutes</option></select></label>
      <div className="phone-agent-actions">{(["ready", "away", "wrap_up"] as const).map(status => <button className="button ghost" type="button" key={status} disabled={busy || loading || stale} onClick={() => void setStatus(status)}>Set {labels[status]}</button>)}</div>
    </>}
  </section>;
}
