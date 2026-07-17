import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { TenantAdministration } from "../../types";
import { errorText, formatBytes, stringValue } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";

export function TenantSettingsPanel({ api, onUpdated }: { api: ApiClient; onUpdated: (state: TenantAdministration) => void }) {
  const [state, setState] = useState<TenantAdministration | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();

  useEffect(() => {
    let current = true;
    api.tenantAdministration().then((value) => current && setState(value)).catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [api]);

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!state) return;
    const values = new FormData(event.currentTarget);
    setBusy(true);
    setError(null);
    try {
      const updated = await runWithStepUp(() => api.updateTenantAdministration({
        name: stringValue(values, "name"),
        allow_audio_calls: values.get("allow_audio_calls") === "on",
        allow_video_calls: values.get("allow_video_calls") === "on",
        allow_public_channels: values.get("allow_public_channels") === "on",
        message_edit_window_seconds: Number(values.get("message_edit_window_seconds")),
        max_attachment_bytes: Number(values.get("max_attachment_bytes")),
        default_retention_days: Number(values.get("default_retention_days")),
        max_active_users: Number(values.get("max_active_users")),
        max_active_conversations: Number(values.get("max_active_conversations")),
        max_conversation_members: Number(values.get("max_conversation_members")),
        version: state.settings.version
      }));
      setState(updated);
      onUpdated(updated);
      setNotice("Workspace settings updated.");
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  if (!state) return <section className="data-card"><div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading tenant settings…</div>{error && <div className="form-error">{error}</div>}</section>;
  return <form className="data-card tenant-settings-form" onSubmit={(event) => void save(event)}>
    <div className="card-heading"><div><span className="eyebrow">Workspace policy</span><h2>Tenant settings</h2></div><span className="status-pill success">Version {state.settings.version}</span></div>
    {error && <div className="form-error" role="alert">{error}</div>}{notice && <div className="inline-notice" role="status">{notice}</div>}
    <section className="quota-usage" aria-labelledby="quota-usage-title">
      <div className="card-heading"><div><span className="eyebrow">Admission safety</span><h3 id="quota-usage-title">Capacity usage</h3></div><span className={`status-pill ${state.usage.over_limit.any ? "danger" : state.usage.at_capacity.any ? "neutral" : "success"}`}>{state.usage.over_limit.any ? "Over limit" : state.usage.at_capacity.any ? "At capacity" : "Within limits"}</span></div>
      {state.usage.over_limit.any && <div className="inline-notice error" role="alert">This tenant is over one or more admission limits. Existing data remains available, but new admissions are blocked until usage or limits are corrected.</div>}
      {!state.usage.over_limit.any && state.usage.at_capacity.any && <div className="inline-notice" role="status">One or more admission limits are at capacity. The next admission for a full category is blocked until usage falls or its limit increases.</div>}
      <dl className="quota-usage-grid">
        <QuotaUsage label="Active identities" current={state.usage.active_users} limit={state.usage.limits.max_active_users} over={state.usage.over_limit.active_users} />
        <QuotaUsage label="Active conversations" current={state.usage.active_conversations} limit={state.usage.limits.max_active_conversations} over={state.usage.over_limit.active_conversations} />
        <QuotaUsage label="Largest active conversation" current={state.usage.largest_conversation_members} limit={state.usage.limits.max_conversation_members} over={state.usage.over_limit.conversation_members} />
      </dl>
    </section>
    <div className="settings-grid form-grid">
      <label className="field">Workspace name<input name="name" defaultValue={state.tenant.name} required maxLength={120} /></label>
      <label className="field">Message edit window (seconds)<input name="message_edit_window_seconds" type="number" min={0} max={2_592_000} defaultValue={state.settings.message_edit_window_seconds} required /></label>
      <label className="field">Attachment limit (bytes)<input name="max_attachment_bytes" type="number" min={1024} max={1_000_000_000} defaultValue={state.settings.max_attachment_bytes} required /><small>Current limit: {formatBytes(state.settings.max_attachment_bytes)}</small></label>
      <label className="field">Default retention (days)<input name="default_retention_days" type="number" min={1} max={36500} defaultValue={state.settings.default_retention_days} required /></label>
      <label className="field">Maximum active identities<input name="max_active_users" type="number" min={1} max={1_000_000} defaultValue={state.settings.max_active_users} required /><small>Human and service identities share this capacity.</small></label>
      <label className="field">Maximum active conversations<input name="max_active_conversations" type="number" min={1} max={10_000_000} defaultValue={state.settings.max_active_conversations} required /><small>Archived conversations do not consume capacity.</small></label>
      <label className="field">Maximum members per conversation<input name="max_conversation_members" type="number" min={2} max={100_000} defaultValue={state.settings.max_conversation_members} required /><small>At least two preserves direct conversations; left memberships do not consume capacity.</small></label>
    </div>
    <label className="checkbox-field"><input name="allow_audio_calls" type="checkbox" defaultChecked={state.settings.allow_audio_calls} />Allow members to start and join audio calls</label>
    <label className="checkbox-field"><input name="allow_video_calls" type="checkbox" defaultChecked={state.settings.allow_video_calls} />Allow members to start and join video calls</label>
    <label className="checkbox-field"><input name="allow_public_channels" type="checkbox" defaultChecked={state.settings.allow_public_channels} />Allow workspace-visible public channels</label>
    <div className="form-actions"><button className="button primary" type="submit" disabled={busy}>{busy ? "Saving…" : "Save workspace settings"}</button></div>
  </form>;
}

function QuotaUsage({ label, current, limit, over }: { label: string; current: number; limit: number; over: boolean }) {
  return <div className={over ? "quota-over" : undefined}><dt>{label}</dt><dd>{current.toLocaleString()} of {limit.toLocaleString()}{over && <span className="visually-hidden">, over limit</span>}</dd></div>;
}
