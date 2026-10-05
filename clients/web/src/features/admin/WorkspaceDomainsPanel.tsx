import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import { ApiError } from "../../api/errors";
import { useSession } from "../../app/session";
import { StepUpCancelledError, stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { ActionDialog } from "../../components/ActionDialog";
import { canonicalWorkspaceDomain } from "../../lib/workspaceDiscovery";
import { formatDateTime } from "../../lib/format";
import { canAdministerTenant } from "../../lib/roles";
import type { WorkspaceDomainClaim, WorkspaceDomainInventory } from "../../types/workspaceDiscovery";
import "./WorkspaceDomainsPanel.css";

type DomainsApi = Pick<ApiClient, "workspaceDomains" | "createWorkspaceDomain" | "renewWorkspaceDomain" | "verifyWorkspaceDomain" | "updateWorkspaceDomainDiscovery" | "removeWorkspaceDomain">;
type DomainAction = { id: string; kind: "renew" } | { id: string; kind: "verify" } |
  { id: string; kind: "remove" } | { id: string; kind: "discovery"; enabled: boolean };

export function WorkspaceDomainsPanel({ api }: { api: DomainsApi }) {
  const { session } = useSession();
  const allowed = Boolean(session && session.tenant.status === "active" && session.user.status === "active" && canAdministerTenant(session.user.role) &&
    (session.user.account_type || "human") === "human" && (session.user.access_scope || "workspace") === "workspace");
  const scope = `${session?.tenant.id || ""}:${session?.tenant.status || ""}:${session?.user.id || ""}:${session?.user.role || ""}:${session?.user.status || ""}:${session?.user.version || ""}:${session?.device?.id || ""}:${session?.access_token || ""}`;
  const identity = useRef({ scope, serial: 0 });
  if (identity.current.scope !== scope) identity.current = { scope, serial: identity.current.serial + 1 };
  if (!allowed) return <p role="alert">Domain settings require a current owner or administrator with full workspace access.</p>;
  return <DomainsContent key={identity.current.serial} api={api} />;
}

function DomainsContent({ api }: { api: DomainsApi }) {
  const { runWithStepUp } = useStepUp();
  const [inventory, setInventory] = useState<WorkspaceDomainInventory | null>(null);
  const [domain, setDomain] = useState("");
  const [discovery, setDiscovery] = useState(false);
  const [pending, setPending] = useState<DomainAction | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [denied, setDenied] = useState(false);
  const [clock, setClock] = useState(Date.now);
  const generation = useRef(0);
  const busy = useRef(false);
  const currentInventory = useRef(inventory);
  currentInventory.current = inventory;

  const clearAccess = useCallback(() => {
    currentInventory.current = null; setInventory(null); setDomain(""); setDiscovery(false); setPending(null); setNotice(null); setDenied(true);
    setError("Domain details are unavailable with your current access. Verify your account or ask an authorized owner.");
  }, []);
  const guard = useCallback(async <T,>(request: number, action: () => Promise<T>): Promise<T> => {
    if (request !== generation.current) throw new StepUpCancelledError();
    try { return await action(); }
    catch (reason: unknown) {
      if (request === generation.current && reason instanceof ApiError) {
        if ([401, 403, 404].includes(reason.status) || reason.code === "session_changed") clearAccess();
        else if (reason.code === "step_up_required") {
          const value = currentInventory.current;
          if (value) { const scrubbed = { ...value, data: value.data.map((claim) => ({ ...claim, challenge_value: null })) }; currentInventory.current = scrubbed; setInventory(scrubbed); }
        }
      }
      throw reason;
    }
  }, [clearAccess]);

  const load = useCallback(async (duringMutation = false) => {
    if (busy.current && !duringMutation) return null;
    const request = duringMutation ? generation.current : ++generation.current;
    if (!duringMutation) busy.current = true;
    setLoading(true);
    if (!duringMutation) setError(null);
    try {
      const value = await runWithStepUp(() => guard(request, () => api.workspaceDomains()));
      if (request !== generation.current) return null;
      currentInventory.current = value; setInventory(value); setDenied(false); return value;
    } catch (reason: unknown) {
      if (request === generation.current && !stepUpWasCancelled(reason) && !(reason instanceof ApiError && ([401, 403, 404].includes(reason.status) || reason.code === "session_changed"))) setError("Domain inventory could not be loaded. Verify current state before repeating a change.");
      return null;
    } finally { if (request === generation.current) { setLoading(false); if (!duringMutation) busy.current = false; } }
  }, [api, guard, runWithStepUp]);

  useEffect(() => { void load(); return () => { generation.current += 1; }; }, [load]);
  useEffect(() => {
    const interval = window.setInterval(() => setClock(Date.now()), 15000);
    const revalidate = () => { if (document.visibilityState !== "hidden" && !busy.current && !denied) void load(); };
    window.addEventListener("focus", revalidate); document.addEventListener("visibilitychange", revalidate);
    return () => { window.clearInterval(interval); window.removeEventListener("focus", revalidate); document.removeEventListener("visibilitychange", revalidate); };
  }, [denied, load]);

  async function mutate(action: () => Promise<WorkspaceDomainClaim>, removing = false) {
    if (busy.current || denied || !currentInventory.current) return false;
    const request = ++generation.current;
    busy.current = true; setSaving(true); setError(null); setNotice(null);
    try {
      const claim = await runWithStepUp(() => guard(request, action));
      if (request !== generation.current) return false;
      const current = currentInventory.current;
      const next = current ? { ...current, data: removing ? current.data.filter(({ id }) => id !== claim.id)
        : [...current.data.filter(({ id }) => id !== claim.id), claim] } : null;
      currentInventory.current = next; setInventory(next);
      setPending(null); return true;
    } catch (reason: unknown) {
      if (request !== generation.current || stepUpWasCancelled(reason)) return false;
      if (reason instanceof ApiError && ([401, 403, 404].includes(reason.status) || reason.code === "session_changed")) return false;
      if (reason instanceof ApiError && reason.status === 409) {
        const fresh = await load(true);
        if (request !== generation.current || !fresh) return false;
        setError(domainError(reason));
      } else setError(domainError(reason));
      return false;
    } finally { if (request === generation.current) { busy.current = false; setSaving(false); } }
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const canonical = canonicalWorkspaceDomain(domain);
    if (!canonical) { setError("Enter an exact ASCII domain, not an email address, URL or local/test domain."); return; }
    if (await mutate(() => api.createWorkspaceDomain({ domain: canonical, version: 0, discovery_enabled: discovery }))) {
      setDomain(""); setDiscovery(false); setNotice(discovery
        ? "Domain claim created with discovery opted in. Add its DNS TXT record and verify ownership before a public sign-in hint can be available."
        : "Domain claim created with discovery off. Add its DNS TXT record, verify it, then explicitly enable discovery when you are ready.");
    }
  }
  const selected = pending ? inventory?.data.find(({ id }) => id === pending.id) : undefined;
  async function confirm() {
    if (!pending || !selected || !Number.isSafeInteger(selected.version) || selected.version < 1) return;
    const intent = pending;
    const claim = selected;
    const success = await mutate(() => intent.kind === "renew" ? api.renewWorkspaceDomain(claim.id, claim.version)
      : intent.kind === "verify" ? api.verifyWorkspaceDomain(claim.id, claim.version)
      : intent.kind === "remove" ? api.removeWorkspaceDomain(claim.id, claim.version)
      : api.updateWorkspaceDomainDiscovery(claim.id, claim.version, intent.enabled), intent.kind === "remove");
    if (success) setNotice(intent.kind === "verify" ? "DNS ownership verified. A public hint requires both discovery opt-in and a current proof lease."
      : intent.kind === "renew" ? "New challenge created. Replace the old TXT value before verifying; an existing live proof lease keeps its expiry."
      : intent.kind === "remove" ? "Domain claim removed. Accounts and existing workspace access are unchanged."
      : `Public domain discovery ${intent.enabled ? "enabled" : "disabled"}. Access and enrollment are unchanged.`);
  }

  return <section className="data-card workspace-domains" aria-label="Workspace domain settings">
    <h2>Workspace domains</h2><p>Verify exact DNS ownership and explicitly opt in to public workspace sign-in hints. This does not enroll people, verify their email, grant workspace access or choose an identity provider.</p>
    <p>TXT challenges last 30 minutes; verified proof leases last seven days. Each subdomain needs its own claim. Keep your current workspace address available to members when discovery is off or expired.</p>
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}{loading && <p role="status">Loading domain inventory…</p>}
    <button type="button" className="button ghost compact" disabled={loading || saving} onClick={() => void load()}>Reload domain inventory</button>
    {!denied && <>
      <form className="workspace-domain-create" aria-label="Add workspace domain" onSubmit={(event) => void create(event)} noValidate>
        <label className="field">Domain<input value={domain} maxLength={254} autoCapitalize="none" spellCheck={false} autoComplete="off" disabled={saving} onChange={(event) => setDomain(event.target.value)} placeholder="team.example.org" /></label>
        <label className="workspace-domain-checkbox"><input type="checkbox" checked={discovery} disabled={saving} onChange={(event) => setDiscovery(event.target.checked)} />Opt in to public discovery after verification</label>
        <button type="submit" className="button primary compact" disabled={!inventory || loading || saving || inventory.data.length >= inventory.limits.domains}>Add domain claim</button>
      </form>
      {inventory && <p>{inventory.data.length} / {inventory.limits.domains} retained domain claims.</p>}
      <ul className="workspace-domain-list" aria-label="Workspace domain claims">{inventory?.data.map((claim) => {
        const liveProof = claim.status === "verified" && claim.proof_expires_at !== null && Date.parse(claim.proof_expires_at) > clock;
        const liveChallenge = claim.challenge_value !== null && Date.parse(claim.challenge_expires_at) > clock;
        return <li key={claim.id}><h3>{claim.domain}</h3><p>Status: {liveProof ? "Verified proof lease" : claim.status === "verified" || claim.status === "expired" ? "Proof lease expired" : "Awaiting DNS verification"} · Version {claim.version}.</p>
          <p>Public discovery: {claim.discovery_enabled ? liveProof ? "Enabled" : "Opted in; awaiting a current proof lease" : "Disabled"}.</p>
          {claim.proof_expires_at && <p>Proof expires {formatDateTime(claim.proof_expires_at)}.</p>}
          {claim.verified_at && <p>Last verified {formatDateTime(claim.verified_at)}.</p>}
          {liveChallenge ? <details className="workspace-domain-dns"><summary>DNS TXT instructions for {claim.domain}</summary><p>Add a TXT record with this exact name and value. After publishing it, verify the current challenge before it expires.</p>
            <dl><dt>TXT name</dt><dd><code>{claim.challenge_name}</code></dd><dt>TXT value</dt><dd><code>{claim.challenge_value}</code></dd><dt>Challenge expiry</dt><dd>{formatDateTime(claim.challenge_expires_at)}</dd></dl>
          </details> : <p>{claim.challenge_value ? "The TXT challenge has expired. Create a new challenge before verification." : "No live TXT challenge is shown. Create a new challenge to verify or renew the proof lease."}</p>}
          <div className="workspace-domain-actions">
            <button type="button" className="button ghost compact" disabled={loading || saving} onClick={() => { setError(null); setPending({ id: claim.id, kind: "renew" }); }}>New challenge for {claim.domain}</button>
            <button type="button" className="button secondary compact" disabled={loading || saving || !liveChallenge} onClick={() => { setError(null); setPending({ id: claim.id, kind: "verify" }); }}>Verify DNS for {claim.domain}</button>
            <button type="button" className="button ghost compact" disabled={loading || saving} onClick={() => { setError(null); setPending({ id: claim.id, kind: "discovery", enabled: !claim.discovery_enabled }); }}>{claim.discovery_enabled ? "Disable" : "Enable"} discovery for {claim.domain}</button>
            <button type="button" className="button danger compact" disabled={loading || saving} onClick={() => { setError(null); setPending({ id: claim.id, kind: "remove" }); }}>Remove {claim.domain}</button>
          </div>
        </li>;
      })}</ul>
    </>}
    {pending && selected && <ActionDialog title={pending.kind === "verify" ? "Verify DNS ownership?" : pending.kind === "renew" ? "Replace the DNS challenge?" : pending.kind === "remove" ? "Remove domain claim?" : `${pending.enabled ? "Enable" : "Disable"} public discovery?`}
      description={`${selected.domain} · Current version ${selected.version}.`}
      impact={pending.kind === "renew" ? "The old TXT challenge stops verifying. An existing live proof lease keeps its current expiry; a new verification renews it."
        : pending.kind === "remove" ? "The claim and public discovery hint are removed. Existing accounts and conversation access are unchanged."
        : pending.kind === "verify" ? "Only the current exact DNS challenge can prove ownership. This does not admit users or establish single sign-on."
        : "A public hint is available only while discovery is opted in, the workspace is active and its exact-domain proof lease is current. This grants no account access."}
      confirmLabel={pending.kind === "verify" ? "Verify current DNS challenge" : pending.kind === "renew" ? "Create new challenge" : pending.kind === "remove" ? "Remove claim" : "Apply discovery setting"}
      tone={pending.kind === "remove" ? "danger" : "default"} busy={saving || loading} error={error}
      onCancel={() => { if (!saving && !loading) { setPending(null); setError(null); } }} onConfirm={() => void confirm()} />}
    {pending && !selected && !saving && !loading && !denied && <div role="alert"><p>The selected claim is no longer available. Reload current state before choosing another action.</p><button type="button" onClick={() => setPending(null)}>Dismiss unavailable domain action</button></div>}
  </section>;
}

function domainError(reason: unknown) {
  if (reason instanceof ApiError) {
    if (reason.code === "stale_version") return "This claim changed elsewhere. Current state is reloaded; review it and explicitly retry your pending change.";
    if (reason.code === "domain_challenge_expired") return "The current DNS challenge has expired or was consumed. Review current state and create a new challenge if needed.";
    if (reason.code === "domain_proof_missing") return "DNS does not contain the current TXT proof. Check the exact record and retry verification after it is published.";
    if (reason.code === "domain_limit_reached") return "The domain claim limit has been reached. Remove an unused claim before adding another.";
    if (["domain_already_claimed", "domain_in_use"].includes(reason.code)) return "This domain cannot be claimed or verified right now. Review the current inventory and ask the domain administrator.";
    if (reason.status === 503 && ["dns_timeout", "dns_unavailable"].includes(reason.code)) return "DNS verification is temporarily unavailable. No verification success was recorded; review current state before retrying.";
    if (reason.status === 503) return "Domain administration is temporarily unavailable. No change is confirmed; reload current state before retrying.";
    if (reason.code === "version_required") return "Current claim version is required. Reload the inventory before retrying.";
  }
  return "The domain change could not be confirmed. Reload current state before repeating a request that may have reached the server.";
}
