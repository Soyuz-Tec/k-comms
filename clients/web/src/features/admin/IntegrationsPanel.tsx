import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { WebhookDelivery, WebhookEndpoint } from "../../types";
import { errorText, formatDateTime, stringValue } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { ActionDialog } from "../../components/ActionDialog";
import { AppIcon } from "../../components/AppIcon";
import { ServiceAccountsPanel } from "./ServiceAccountsPanel";
import "./IntegrationsPanel.css";

type PendingEndpointAction = { kind: "rotate" | "disable" | "enable"; endpoint: WebhookEndpoint };
const webhookEvents = [
  ["message.created.v1", "Message sent"],
  ["message.updated.v1", "Message edited"],
  ["message.deleted.v1", "Message deleted"],
  ["mention.created.v1", "Member mentioned"],
  ["conversation.created.v1", "Conversation created"],
  ["conversation.updated.v1", "Conversation updated"],
  ["conversation.archived.v1", "Conversation archived"],
  ["membership.changed.v1", "Conversation membership changed"],
  ["membership.role_changed.v1", "Conversation role changed"],
  ["call.started.v1", "Meeting started"],
  ["call.ended.v1", "Meeting ended"]
] as const;

export function IntegrationsPanel({ api, onServiceAccountLifecycleChanged }: { api: ApiClient; onServiceAccountLifecycleChanged?: () => void | Promise<void> }) {
  const [endpoints, setEndpoints] = useState<WebhookEndpoint[]>([]);
  const [deliveries, setDeliveries] = useState<WebhookDelivery[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [secret, setSecret] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingEndpointAction | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [createEvents, setCreateEvents] = useState<string[]>([]);
  const [editing, setEditing] = useState<WebhookEndpoint | null>(null);
  const [editEvents, setEditEvents] = useState<string[]>([]);
  const [deliveryEndpoint, setDeliveryEndpoint] = useState("");
  const [deliveryStatus, setDeliveryStatus] = useState("");
  const { runWithStepUp } = useStepUp();

  useEffect(() => {
    let current = true;
    Promise.all([api.webhooks(), api.webhookDeliveries()])
      .then(([nextEndpoints, nextDeliveries]) => { if (current) { setEndpoints(nextEndpoints); setDeliveries(nextDeliveries); setLoaded(true); } })
      .catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [api]);

  useEffect(() => {
    if (!secret) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [secret]);

  function replaceEndpoint(endpoint: WebhookEndpoint) {
    setEndpoints((current) => current.map((value) => value.id === endpoint.id ? endpoint : value));
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    if (secret) return setError("Acknowledge the current one-time signing secret before creating another endpoint.");
    if (!createEvents.length) return setError("Choose at least one event for this webhook.");
    const form = event.currentTarget;
    const values = new FormData(form);
    setBusy("create");
    setError(null);
    try {
      const result = await runWithStepUp(() => api.createWebhook({ name: stringValue(values, "name"), url: stringValue(values, "url"), event_types: createEvents }));
      setEndpoints((current) => [result.endpoint, ...current]);
      setSecret(result.secret);
      setCreateEvents([]);
      form.reset();
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally { setBusy(null); }
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editing || busy) return;
    if (!editEvents.length) return setError("Choose at least one event for this webhook.");
    const values = new FormData(event.currentTarget);
    const endpoint = editing;
    setBusy(`edit-${endpoint.id}`);
    setError(null);
    try {
      const updated = await runWithStepUp(() => api.updateWebhook(endpoint.id, { name: stringValue(values, "name"), url: stringValue(values, "url"), event_types: editEvents }));
      replaceEndpoint(updated);
      setEditing(null);
      void api.webhookDeliveries().then(setDeliveries).catch(() => setError("Endpoint saved. Refresh integrations to reload the delivery ledger."));
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally { setBusy(null); }
  }

  async function confirmEndpointAction(reason: string) {
    if (!pendingAction || busy) return;
    const action = pendingAction;
    setBusy(`${action.kind}-${action.endpoint.id}`);
    setActionError(null);
    try {
      if (action.kind === "rotate") {
        const result = await runWithStepUp(() => api.rotateWebhookSecret(action.endpoint.id, reason));
        replaceEndpoint(result.endpoint);
        setSecret(result.secret);
      } else if (action.kind === "enable") {
        replaceEndpoint(await runWithStepUp(() => api.updateWebhook(action.endpoint.id, { status: "active" })));
      } else {
        await runWithStepUp(() => api.disableWebhook(action.endpoint.id, reason));
        replaceEndpoint({ ...action.endpoint, status: "disabled", disabled_at: new Date().toISOString() });
      }
      setPendingAction(null);
    } catch (cause: unknown) {
      if (!stepUpWasCancelled(cause)) setActionError(errorText(cause));
    } finally { setBusy(null); }
  }

  async function replay(delivery: WebhookDelivery) {
    if (busy) return;
    setBusy(`delivery-${delivery.id}`);
    setError(null);
    try {
      const updated = await runWithStepUp(() => api.replayWebhookDelivery(delivery.id));
      setDeliveries((current) => current.map((value) => value.id === updated.id ? updated : value));
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally { setBusy(null); }
  }

  async function refresh() {
    if (busy) return;
    setBusy("refresh");
    setError(null);
    try {
      const [nextEndpoints, nextDeliveries] = await Promise.all([api.webhooks(), api.webhookDeliveries()]);
      setEndpoints(nextEndpoints);
      setDeliveries(nextDeliveries);
      setLoaded(true);
    } catch (reason: unknown) { setError(errorText(reason)); }
    finally { setBusy(null); }
  }

  async function copy(value: string) {
    try { await navigator.clipboard.writeText(value); }
    catch { setError("Clipboard access is unavailable. Select and copy the text manually."); }
  }

  const endpointById = new Map(endpoints.map((endpoint) => [endpoint.id, endpoint]));
  const visibleDeliveries = deliveries.filter((delivery) => (!deliveryEndpoint || delivery.endpoint_id === deliveryEndpoint) && (!deliveryStatus || delivery.status === deliveryStatus));
  return <>
    {error && <div className="inline-notice error" role="alert">{error}<button className="button ghost compact" type="button" disabled={Boolean(busy)} onClick={() => void refresh()}>Reload integrations</button><button type="button" aria-label="Dismiss integrations error" onClick={() => setError(null)}><AppIcon name="x" /></button></div>}
    {pendingAction && <ActionDialog
      title={pendingAction.kind === "rotate" ? "Rotate signing secret?" : pendingAction.kind === "enable" ? "Enable webhook endpoint?" : "Disable webhook endpoint?"}
      description={`${pendingAction.endpoint.name} · ${pendingAction.endpoint.url}`}
      impact={pendingAction.kind === "rotate" ? "The existing signing secret will stop working. Every consumer must be updated with the new one-time secret." : pendingAction.kind === "enable" ? "K-Comms will send new matching events to this URL. Existing failed deliveries are not replayed automatically." : "K-Comms will stop sending new webhook deliveries to this endpoint."}
      confirmLabel={pendingAction.kind === "rotate" ? "Rotate secret" : pendingAction.kind === "enable" ? "Enable endpoint" : "Disable endpoint"}
      tone={pendingAction.kind === "enable" ? "default" : "danger"}
      auditReason={pendingAction.kind === "enable" ? undefined : { helpText: "This reason is retained in the audit record.", minimumLength: 3 }}
      busy={busy !== null}
      error={actionError}
      onCancel={() => { if (!busy) { setPendingAction(null); setActionError(null); } }}
      onConfirm={(reason) => void confirmEndpointAction(reason)}
    />}
    <ServiceAccountsPanel api={api} onLifecycleChanged={onServiceAccountLifecycleChanged} />
    <section className="data-card integration-endpoints">
      <div className="card-heading"><div><span className="eyebrow">Signed delivery</span><h2>Webhook endpoints</h2></div><div className="integration-heading-actions"><span className="status-pill neutral">{loaded ? `${endpoints.length} configured` : "Loading…"}</span><button className="button ghost compact" type="button" disabled={Boolean(busy)} onClick={() => void refresh()}>Refresh</button></div></div>
      <form className="webhook-edit-form" aria-label="Create webhook" onSubmit={(event) => void create(event)}>
        <div className="inline-admin-form"><label className="field">Name<input name="name" required disabled={Boolean(busy)} /></label><label className="field grow-field">HTTPS URL<input name="url" type="url" placeholder="https://example.test/hooks/k-comms" required disabled={Boolean(busy)} /></label></div>
        <WebhookEventPicker selected={createEvents} onChange={setCreateEvents} disabled={Boolean(busy)} />
        <button className="button primary" type="submit" disabled={Boolean(busy) || Boolean(secret)}>Create webhook</button>
      </form>
      {secret && <div className="secret-reveal" role="region" aria-label="One-time signing secret"><strong>One-time signing secret</strong><code>{secret}</code><button className="button ghost compact" type="button" onClick={() => void copy(secret)}>Copy secret</button><button className="text-button" type="button" onClick={() => setSecret(null)}>I stored it</button></div>}
      {editing && <form className="webhook-edit-form" aria-label={`Edit webhook ${editing.name}`} key={editing.id} onSubmit={(event) => void save(event)}>
        <h3>Edit {editing.name}</h3><p>Changing the URL cancels pending deliveries to the previous destination. The existing signing secret remains in use.</p>
        <div className="inline-admin-form"><label className="field">Endpoint name<input name="name" defaultValue={editing.name} required disabled={Boolean(busy)} /></label><label className="field grow-field">Endpoint HTTPS URL<input name="url" type="url" defaultValue={editing.url} required disabled={Boolean(busy)} /></label></div>
        <WebhookEventPicker selected={editEvents} onChange={setEditEvents} disabled={Boolean(busy)} />
        <div className="form-actions"><button className="button ghost" type="button" disabled={Boolean(busy)} onClick={() => setEditing(null)}>Cancel editing</button><button className="button primary" type="submit" disabled={Boolean(busy)}>Save endpoint</button></div>
      </form>}
      {loaded && endpoints.length === 0 && <p className="empty-copy">No webhook endpoints configured.</p>}
      <ul className="security-list">{endpoints.map((endpoint) => <li key={endpoint.id}>
        <div className="integration-endpoint-copy"><strong>{endpoint.name}</strong><small>{endpoint.url}</small><small>Signing secret version {endpoint.secret_version} · {endpoint.event_types.map(eventLabel).join(", ")}</small><small>Updated {formatDateTime(endpoint.updated_at)}{endpoint.disabled_at ? ` · Disabled ${formatDateTime(endpoint.disabled_at)}` : ""}</small></div>
        <span className={`status-pill ${endpoint.status === "active" ? "success" : "neutral"}`}>{endpoint.status === "active" ? "Enabled" : "Disabled"}</span>
        <button className="button ghost compact" type="button" aria-label={`Edit ${endpoint.name}`} disabled={Boolean(busy)} onClick={() => { setEditing(endpoint); setEditEvents([...endpoint.event_types]); }}>Edit</button>
        {endpoint.status === "active" ? <>
          <button className="button ghost compact" type="button" disabled={Boolean(secret) || Boolean(busy)} onClick={() => { setActionError(null); setPendingAction({ kind: "rotate", endpoint }); }}>Rotate secret</button>
          <button className="button danger compact" type="button" disabled={Boolean(busy)} onClick={() => { setActionError(null); setPendingAction({ kind: "disable", endpoint }); }}>Disable</button>
        </> : <button className="button primary compact" type="button" disabled={Boolean(busy)} onClick={() => { setActionError(null); setPendingAction({ kind: "enable", endpoint }); }}>Enable</button>}
      </li>)}</ul>
    </section>
    <section className="data-card integration-deliveries">
      <div className="card-heading"><div><span className="eyebrow">Delivery ledger</span><h2>Webhook deliveries</h2></div><span className="status-pill neutral">{deliveries.length} recent</span></div>
      <p className="empty-copy">Filters apply to these recent deliveries. Endpoint status indicates configuration; recent successful deliveries show past reachability.</p>
      <div className="inline-admin-form"><label className="field">Delivery endpoint<select value={deliveryEndpoint} onChange={(event) => setDeliveryEndpoint(event.currentTarget.value)}><option value="">All endpoints</option>{endpoints.map((endpoint) => <option key={endpoint.id} value={endpoint.id}>{endpoint.name}</option>)}</select></label><label className="field">Delivery status<select value={deliveryStatus} onChange={(event) => setDeliveryStatus(event.currentTarget.value)}><option value="">All statuses</option>{[...new Set(deliveries.map((delivery) => delivery.status))].sort().map((status) => <option key={status} value={status}>{status.replaceAll("_", " ")}</option>)}</select></label></div>
      {visibleDeliveries.length === 0 ? <p className="empty-copy">{deliveries.length ? "No recent deliveries match these filters." : "No webhook deliveries."}</p> : <ul className="security-list">{visibleDeliveries.map((delivery) => {
        const endpoint = endpointById.get(delivery.endpoint_id);
        return <li key={delivery.id}>
          <div className="integration-endpoint-copy"><strong>{eventLabel(delivery.event_type)}</strong><small>{endpoint?.name || `Endpoint ${delivery.endpoint_id.slice(0, 8)}`} · {delivery.attempt_count} attempts · {formatDateTime(delivery.inserted_at)}</small>
            <details className="integration-delivery-details"><summary>Delivery details</summary><dl><div><dt>Delivery ID</dt><dd>{delivery.id}</dd></div><div><dt>Endpoint ID</dt><dd>{delivery.endpoint_id}</dd></div><div><dt>Event</dt><dd>{delivery.event_type}</dd></div>{endpoint && <div><dt>Current endpoint URL</dt><dd>{endpoint.url}</dd></div>}{delivery.response_status != null && <div><dt>HTTP response</dt><dd>{delivery.response_status}</dd></div>}{delivery.last_error_code && <div><dt>Failure</dt><dd>{delivery.last_error_code}</dd></div>}{delivery.last_attempt_at && <div><dt>Last attempt</dt><dd>{formatDateTime(delivery.last_attempt_at)}</dd></div>}{delivery.next_attempt_at && <div><dt>Next attempt</dt><dd>{formatDateTime(delivery.next_attempt_at)}</dd></div>}{delivery.delivered_at && <div><dt>Delivered</dt><dd>{formatDateTime(delivery.delivered_at)}</dd></div>}</dl>{delivery.last_error_code && <button className="button ghost compact" type="button" onClick={() => void copy(`Delivery ${delivery.id}\nEndpoint ${delivery.endpoint_id}\nEvent ${delivery.event_type}\nHTTP ${delivery.response_status ?? "none"}\nError ${delivery.last_error_code}`)}>Copy failure details</button>}</details>
          </div>
          <span className={`status-pill ${delivery.status === "delivered" ? "success" : "neutral"}`}>{delivery.status.replaceAll("_", " ")}</span>
          {["failed", "dead_letter"].includes(delivery.status) && <button className="button ghost compact" type="button" disabled={Boolean(busy) || endpoint?.status === "disabled"} title={endpoint?.status === "disabled" ? "Enable the endpoint before replaying" : undefined} onClick={() => void replay(delivery)}>Replay</button>}
        </li>;
      })}</ul>}
    </section>
  </>;
}

function eventLabel(event: string): string {
  return webhookEvents.find(([value]) => value === event)?.[1] ?? event;
}

function WebhookEventPicker({ selected, onChange, disabled }: { selected: string[]; onChange: (events: string[]) => void; disabled: boolean }) {
  const options = [...webhookEvents.map(([value]) => value as string), ...selected.filter((value) => !webhookEvents.some(([event]) => event === value))];
  return <fieldset className="webhook-event-picker" disabled={disabled}><legend>Events to deliver</legend>{options.map((value) => <label key={value}><input type="checkbox" checked={selected.includes(value)} onChange={(event) => onChange(event.currentTarget.checked ? [...selected, value] : selected.filter((item) => item !== value))} /><span>{eventLabel(value)}<small>{value}</small></span></label>)}</fieldset>;
}
