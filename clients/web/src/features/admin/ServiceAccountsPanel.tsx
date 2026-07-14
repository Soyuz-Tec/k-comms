import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import type { ServiceAccount, ServiceAccountScope } from "../../types";
import { errorText, formatDateTime, stringValue } from "../../lib/format";
import { ActionDialog } from "../../components/ActionDialog";

export const serviceAccountScopes: ServiceAccountScope[] = [
  "conversations:read",
  "messages:read",
  "messages:write",
  "search:read"
];

export function ServiceAccountsPanel({ api, onLifecycleChanged }: { api: ApiClient; onLifecycleChanged?: () => void | Promise<void> }) {
  const [accounts, setAccounts] = useState<ServiceAccount[]>([]);
  const [credential, setCredential] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<{ kind: "rotate" | "revoke"; account: ServiceAccount } | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setAccounts(await runWithStepUp(() => api.serviceAccounts()));
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setLoading(false);
    }
  }, [api, runWithStepUp]);

  useEffect(() => { void load(); }, [load]);

  useEffect(() => {
    if (!credential) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [credential]);

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (credential) return setError("Acknowledge the current one-time credential before creating another service account.");
    const form = event.currentTarget;
    const values = new FormData(form);
    const scopes = values.getAll("scopes").map(String) as ServiceAccountScope[];
    const expiresAt = new Date(stringValue(values, "expires_at"));
    if (scopes.length === 0) return setError("Select at least one service scope.");
    if (Number.isNaN(expiresAt.getTime())) return setError("Choose a valid credential expiry.");
    setBusy("create"); setError(null);
    try {
      const result = await runWithStepUp(() => api.createServiceAccount({
        name: stringValue(values, "name"),
        scopes,
        expires_at: expiresAt.toISOString(),
        reason: stringValue(values, "reason")
      }));
      setAccounts((current) => [result.account, ...current]);
      setCredential(result.credential);
      await onLifecycleChanged?.();
      form.reset();
      const expiryInput = form.elements.namedItem("expires_at");
      if (expiryInput instanceof HTMLInputElement) expiryInput.value = defaultExpiry();
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function confirmAction(reason: string) {
    if (!pendingAction) return;
    const { kind, account } = pendingAction;
    setBusy(`${kind}-${account.id}`); setActionError(null);
    try {
      if (kind === "rotate") {
        const result = await runWithStepUp(() => api.rotateServiceAccount(account.id, account.version, reason));
        setAccounts((current) => current.map((value) => value.id === account.id ? result.account : value));
        setCredential(result.credential);
      } else {
        const updated = await runWithStepUp(() => api.revokeServiceAccount(account.id, account.version, reason));
        setAccounts((current) => current.map((value) => value.id === account.id ? updated : value));
        await onLifecycleChanged?.();
      }
      setPendingAction(null);
    } catch (cause: unknown) {
      if (!stepUpWasCancelled(cause)) setActionError(errorText(cause));
    } finally {
      setBusy(null);
    }
  }

  return <section className="data-card" aria-labelledby="service-accounts-title">
    {pendingAction && <ActionDialog
      title={pendingAction.kind === "rotate" ? "Rotate service credential?" : "Revoke service account?"}
      description={pendingAction.account.name}
      impact={pendingAction.kind === "rotate" ? "The existing credential will stop working immediately. Store and deploy the new one-time credential before the automation runs again." : "The credential will stop working immediately and this bot will lose API access."}
      confirmLabel={pendingAction.kind === "rotate" ? "Rotate credential" : "Revoke account"}
      tone="danger"
      auditReason={{ helpText: "This reason is retained in the audit record.", minimumLength: 3 }}
      busy={busy !== null}
      error={actionError}
      onCancel={() => { if (!busy) { setPendingAction(null); setActionError(null); } }}
      onConfirm={(reason) => void confirmAction(reason)}
    />}
    <div className="card-heading"><div><span className="eyebrow">Scoped automation</span><h2 id="service-accounts-title">Service accounts</h2></div><span className="status-pill success">{loading ? "Loading" : `${accounts.length} configured`}</span></div>
    <p className="support-note">Non-login bot identities can access only joined conversations and explicitly granted API scopes. After creation, add the bot from a conversation’s member controls. Credentials never work for browser sessions, administration, or sockets.</p>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" aria-label="Dismiss service account error" onClick={() => setError(null)}>×</button></div>}
    <form className="inline-admin-form service-account-form" onSubmit={(event) => void create(event)}>
      <label className="field">Bot name<input name="name" required minLength={2} maxLength={120} /></label>
      <label className="field">Credential expires<input name="expires_at" type="datetime-local" defaultValue={defaultExpiry()} min={minimumExpiry()} max={maximumExpiry()} required /></label>
      <fieldset className="scope-fieldset"><legend>Scopes</legend><div className="scope-grid">{serviceAccountScopes.map((scope) => <label className="checkbox-field" key={scope}><input name="scopes" type="checkbox" value={scope} defaultChecked={scope !== "search:read"} />{scope}</label>)}</div></fieldset>
      <label className="field grow-field">Creation reason<input name="reason" required minLength={3} maxLength={1000} /></label>
      <button className="button primary" type="submit" disabled={busy === "create" || Boolean(credential)}>Create service account</button>
    </form>
    {credential && <div className="secret-reveal" role="region" aria-label="One-time service credential"><strong>One-time service credential</strong><code>{credential}</code><small>Store it now. K-Comms keeps only a one-way secret digest and cannot show it again.</small><button className="button ghost compact" type="button" onClick={() => void navigator.clipboard.writeText(credential)}>Copy credential</button><button className="text-button" type="button" onClick={() => setCredential(null)}>I stored it</button></div>}
    {!loading && accounts.length === 0 ? <p className="empty-copy">No service accounts configured.</p> : <ul className="security-list service-account-list">{accounts.map((account) => {
      const status = displayedStatus(account);
      return <li key={account.id}><div><strong>{account.name} <span className="role-chip">Bot</span></strong><small><code>{account.credential_prefix}.••••{account.secret_hint}</code> · Expires {formatDateTime(account.expires_at)} · Last used {account.last_used_at ? formatDateTime(account.last_used_at) : "never"}</small><span className="scope-list">{account.scopes.map((scope) => <span className="status-pill neutral" key={scope}>{scope}</span>)}</span></div><span className={`status-pill ${status === "active" ? "success" : "neutral"}`}>{status}</span>{status === "active" && <><button className="button ghost compact" type="button" disabled={Boolean(credential) || busy === `rotate-${account.id}`} onClick={() => { if (credential) { setError("Acknowledge the current one-time credential before rotating another service account."); return; } setActionError(null); setPendingAction({ kind: "rotate", account }); }}>Rotate credential</button><button className="button danger compact" type="button" disabled={busy === `revoke-${account.id}`} onClick={() => { setActionError(null); setPendingAction({ kind: "revoke", account }); }}>Revoke</button></>}</li>;
    })}</ul>}
  </section>;
}

function displayedStatus(account: ServiceAccount): ServiceAccount["status"] {
  return account.status === "active" && new Date(account.expires_at).getTime() <= Date.now() ? "expired" : account.status;
}

function defaultExpiry(): string {
  const value = new Date(Date.now() + 90 * 24 * 60 * 60 * 1000);
  value.setSeconds(0, 0);
  return localDateTime(value);
}

function minimumExpiry(): string {
  const value = new Date(Date.now() + 5 * 60 * 1000);
  value.setSeconds(0, 0);
  return localDateTime(value);
}

function maximumExpiry(): string {
  const value = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000);
  value.setSeconds(0, 0);
  return localDateTime(value);
}

function localDateTime(value: Date): string {
  const offset = value.getTimezoneOffset() * 60_000;
  return new Date(value.getTime() - offset).toISOString().slice(0, 16);
}
