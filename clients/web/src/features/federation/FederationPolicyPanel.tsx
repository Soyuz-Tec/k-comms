import { useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { FederationTrust } from "../../types/federation";
import { errorText } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import "./FederationPanel.css";
export function FederationPolicyPanel({ api }: { api: ApiClient }) {
  const [trusts, setTrusts] = useState<FederationTrust[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();
  async function load() { setBusy(true); try { setTrusts(await api.federationTrusts()); setLoaded(true); } catch (e) { setError(errorText(e)); } finally { setBusy(false); } }
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy) return;
    const form = event.currentTarget; const values = new FormData(form);
    const domain = String(values.get("domain") || "");
    const existing = trusts.find(trust => trust.domain === domain);
    setBusy(true); setError(null);
    try {
      await runWithStepUp(() => api.putFederationTrust({ domain, residency: String(values.get("residency") || ""), cross_border_reason: String(values.get("reason") || ""), enabled: values.get("enabled") === "on", version: existing?.version }));
      setTrusts(await api.federationTrusts()); form.reset();
    } catch (e) { if (!stepUpWasCancelled(e)) setError(errorText(e)); } finally { setBusy(false); }
  }
  return <details className="federation-panel" onToggle={e => { if(e.currentTarget.open && !loaded && !busy) void load(); }}><summary>Approved external Matrix workspaces</summary>
    <p>Federation is disabled until an operator configures and qualifies a maintained Matrix homeserver. Approving a domain never trusts email addresses or joins anyone automatically. Residency below is an administrator declaration.</p>
    {error && <p role="alert" className="form-error">{error}</p>}
    <button type="button" className="button compact" disabled={busy} onClick={() => void load()}>Reload approved workspaces</button>
    <ul>{trusts.map(trust => <li key={trust.id}><strong>{trust.domain}</strong> · {trust.enabled ? "approved" : "disabled"} · {trust.residency} (declared)<p>{trust.cross_border_reason}</p><small>Version {trust.version}</small></li>)}</ul>
    <form onSubmit={save}><label className="field">Exact lowercase server domain<input name="domain" maxLength={253} required autoComplete="off" /></label><label className="field">Declared data residency<input name="residency" minLength={2} maxLength={80} required /></label><label className="field">Reviewed cross-workspace processing reason<textarea name="reason" minLength={10} maxLength={500} required /></label><label className="checkbox-row"><input type="checkbox" name="enabled" />Approve this workspace for explicit plaintext invitations</label><button className="button primary compact" disabled={busy}>Save policy with identity verification</button><p>Disabling an existing domain fences its bridge rooms and queues cleanup. Re-enabling the domain does not resume fenced rooms.</p></form>
  </details>;
}
