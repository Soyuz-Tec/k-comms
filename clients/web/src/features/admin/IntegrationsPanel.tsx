import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { WebhookDelivery, WebhookEndpoint } from "../../types";
import { errorText, formatDateTime, stringValue } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { ActionDialog } from "../../components/ActionDialog";
import { ServiceAccountsPanel } from "./ServiceAccountsPanel";

type PendingEndpointAction = { kind: "rotate" | "disable"; endpoint: WebhookEndpoint };

export function IntegrationsPanel({ api, onServiceAccountLifecycleChanged }: { api: ApiClient; onServiceAccountLifecycleChanged?: () => void | Promise<void> }) {
  const [endpoints, setEndpoints] = useState<WebhookEndpoint[]>([]);
  const [deliveries, setDeliveries] = useState<WebhookDelivery[]>([]);
  const [secret, setSecret] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingEndpointAction | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();

  useEffect(() => {
    let current = true;
    Promise.all([api.webhooks(), api.webhookDeliveries()]).then(([nextEndpoints, nextDeliveries]) => { if (current) { setEndpoints(nextEndpoints); setDeliveries(nextDeliveries); } }).catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [api]);

  useEffect(() => {
    if (!secret) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [secret]);

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const form = event.currentTarget; const values = new FormData(form); setBusy("create"); setError(null);
    if (secret) { setBusy(null); return setError("Acknowledge the current one-time signing secret before creating another endpoint."); }
    try { const result = await runWithStepUp(() => api.createWebhook({ name: stringValue(values, "name"), url: stringValue(values, "url"), event_types: stringValue(values, "event_types").split(",").map((value) => value.trim()).filter(Boolean) })); setEndpoints((current) => [result.endpoint, ...current]); setSecret(result.secret); form.reset(); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  async function confirmEndpointAction(reason: string) {
    if (!pendingAction) return;
    const action = pendingAction;
    setBusy(`${action.kind}-${action.endpoint.id}`);
    setActionError(null);
    try {
      if (action.kind === "rotate") {
        const result = await runWithStepUp(() => api.rotateWebhookSecret(action.endpoint.id, reason));
        setEndpoints((current) => current.map((value) => value.id === result.endpoint.id ? result.endpoint : value));
        setSecret(result.secret);
      } else {
        await runWithStepUp(() => api.disableWebhook(action.endpoint.id, reason));
        setEndpoints((current) => current.map((value) => value.id === action.endpoint.id ? { ...value, status: "disabled", disabled_at: new Date().toISOString() } : value));
      }
      setPendingAction(null);
    } catch (cause: unknown) {
      if (!stepUpWasCancelled(cause)) setActionError(errorText(cause));
    } finally {
      setBusy(null);
    }
  }

  async function replay(delivery: WebhookDelivery) {
    setBusy(`delivery-${delivery.id}`); try { const updated = await runWithStepUp(() => api.replayWebhookDelivery(delivery.id)); setDeliveries((current) => current.map((value) => value.id === updated.id ? updated : value)); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  return <>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" onClick={() => setError(null)}>×</button></div>}
    {pendingAction && <ActionDialog
      title={pendingAction.kind === "rotate" ? "Rotate signing secret?" : "Disable webhook endpoint?"}
      description={pendingAction.endpoint.name}
      impact={pendingAction.kind === "rotate" ? "The existing signing secret will stop working. Every consumer must be updated with the new one-time secret." : "K-Comms will stop sending new webhook deliveries to this endpoint."}
      confirmLabel={pendingAction.kind === "rotate" ? "Rotate secret" : "Disable endpoint"}
      tone="danger"
      auditReason={{ helpText: "This reason is retained in the audit record.", minimumLength: 3 }}
      busy={busy !== null}
      error={actionError}
      onCancel={() => { if (!busy) { setPendingAction(null); setActionError(null); } }}
      onConfirm={(reason) => void confirmEndpointAction(reason)}
    />}
    <ServiceAccountsPanel api={api} onLifecycleChanged={onServiceAccountLifecycleChanged} />
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Signed delivery</span><h2>Webhook endpoints</h2></div><span className="status-pill success">Live API</span></div><form className="inline-admin-form webhook-form" onSubmit={(event) => void create(event)}><label className="field">Name<input name="name" required /></label><label className="field grow-field">HTTPS URL<input name="url" type="url" placeholder="https://example.test/hooks/k-comms" required /></label><label className="field grow-field">Event types<input name="event_types" placeholder="message.created.v1, conversation.created.v1" required /></label><button className="button primary" type="submit" disabled={busy === "create" || Boolean(secret)}>Create webhook</button></form>{secret && <div className="secret-reveal" role="region" aria-label="One-time signing secret"><strong>One-time signing secret</strong><code>{secret}</code><button className="button ghost compact" type="button" onClick={() => void navigator.clipboard.writeText(secret)}>Copy secret</button><button className="text-button" type="button" onClick={() => setSecret(null)}>I stored it</button></div>}<ul className="security-list">{endpoints.map((endpoint) => <li key={endpoint.id}><div><strong>{endpoint.name}</strong><small>{endpoint.url} · v{endpoint.secret_version} · {endpoint.event_types.join(", ")}</small></div><span className={`status-pill ${endpoint.status === "active" ? "success" : "neutral"}`}>{endpoint.status}</span>{endpoint.status === "active" && <><button className="button ghost compact" type="button" disabled={Boolean(secret) || busy === `rotate-${endpoint.id}`} onClick={() => { if (secret) { setError("Acknowledge the current one-time signing secret before rotating another secret."); return; } setActionError(null); setPendingAction({ kind: "rotate", endpoint }); }}>Rotate secret</button><button className="button danger compact" type="button" disabled={busy === `disable-${endpoint.id}`} onClick={() => { setActionError(null); setPendingAction({ kind: "disable", endpoint }); }}>Disable</button></>}</li>)}</ul></section>
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Delivery ledger</span><h2>Webhook deliveries</h2></div><span className="status-pill success">{deliveries.length} recent</span></div>{deliveries.length === 0 ? <p className="empty-copy">No webhook deliveries.</p> : <ul className="security-list">{deliveries.map((delivery) => <li key={delivery.id}><div><strong>{delivery.event_type}</strong><small>Endpoint {delivery.endpoint_id.slice(0, 8)} · {delivery.attempt_count} attempts · {formatDateTime(delivery.inserted_at)}{delivery.last_error_code ? ` · ${delivery.last_error_code}` : ""}</small></div><span className={`status-pill ${delivery.status === "delivered" ? "success" : "neutral"}`}>{delivery.status}</span>{["failed", "dead_letter"].includes(delivery.status) && <button className="button ghost compact" type="button" disabled={busy === `delivery-${delivery.id}`} onClick={() => void replay(delivery)}>Replay</button>}</li>)}</ul>}</section>
  </>;
}
