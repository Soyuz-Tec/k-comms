import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { TenantAdministration } from "../../types";
import { errorText, formatBytes } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import "./TenantSettingsPanel.css";

interface WorkspaceDraft {
  name: string;
  allow_audio_calls: boolean;
  allow_video_calls: boolean;
  allow_calendar_export: boolean;
  allow_public_channels: boolean;
  message_edit_window_minutes: string;
  max_attachment_mb: string;
  default_retention_days: string;
  max_active_users: string;
  max_active_conversations: string;
  max_conversation_members: string;
}

function workspaceDraft(state: TenantAdministration): WorkspaceDraft {
  return {
    name: state.tenant.name,
    allow_audio_calls: state.settings.allow_audio_calls,
    allow_video_calls: state.settings.allow_video_calls,
    allow_calendar_export: state.settings.allow_calendar_export ?? false,
    allow_public_channels: state.settings.allow_public_channels,
    message_edit_window_minutes: String(state.settings.message_edit_window_seconds / 60),
    max_attachment_mb: String(state.settings.max_attachment_bytes / 1_000_000),
    default_retention_days: String(state.settings.default_retention_days),
    max_active_users: String(state.settings.max_active_users),
    max_active_conversations: String(state.settings.max_active_conversations),
    max_conversation_members: String(state.settings.max_conversation_members)
  };
}

function wholeUnits(value: string, scale: number, label: string, minimum: number, maximum: number): number {
  if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(value) || value.length > 64) {
    throw new Error(`${label}: enter a decimal number.`);
  }
  const [whole, fraction = ""] = value.split(".");
  const numerator = BigInt(`${whole || "0"}${fraction}`) * BigInt(scale);
  const denominator = 10n ** BigInt(fraction.length);
  if (numerator % denominator !== 0n) {
    throw new Error(`${label}: use a value that represents whole ${scale === 60 ? "seconds" : scale === 1_000_000 ? "bytes" : "units"}.`);
  }
  const result = Number(numerator / denominator);
  if (!Number.isSafeInteger(result) || result < minimum || result > maximum) {
    throw new Error(`${label}: choose a value between ${minimum / scale} and ${maximum / scale}.`);
  }
  return result;
}

const impacts: Record<keyof WorkspaceDraft, { label: string; impact: string; unit?: string }> = {
  name: { label: "Workspace name", impact: "Updates the workspace name shown to members." },
  allow_audio_calls: { label: "Audio calls", impact: "Members' access to audio calls follows this setting." },
  allow_calendar_export: { label: "Calendar export", impact: "Allows explicit per-meeting export to a connected calendar. Disabling withdraws consent and queues managed event cleanup." },
  allow_video_calls: { label: "Video calls", impact: "Members' access to video calls follows this setting." },
  allow_public_channels: { label: "Public channels", impact: "Controls whether members can create workspace-visible public channels." },
  message_edit_window_minutes: { label: "Message edit window", unit: "minutes", impact: "Changes how long members can edit their messages." },
  max_attachment_mb: { label: "Attachment limit", unit: "MB", impact: "Applies to new uploads; existing files are retained." },
  default_retention_days: { label: "Default retention", unit: "days", impact: "Older content may become eligible for scheduled deletion. Scoped policies and legal holds still apply." },
  max_active_users: { label: "Active identity limit", impact: "New identities use this limit; existing records remain available." },
  max_active_conversations: { label: "Active conversation limit", impact: "New conversations use this limit; existing records remain available." },
  max_conversation_members: { label: "Conversation member limit", impact: "New memberships use this limit; existing records remain available." }
};

function changeValue(value: string | boolean, unit?: string): string {
  return typeof value === "boolean" ? value ? "Enabled" : "Disabled" : `${value}${unit ? ` ${unit}` : ""}`;
}

export function TenantSettingsPanel({ api, onUpdated }: { api: ApiClient; onUpdated: (state: TenantAdministration) => void }) {
  const [state, setState] = useState<TenantAdministration | null>(null);
  const [draft, setDraft] = useState<WorkspaceDraft | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();

  useEffect(() => {
    let current = true;
    api.tenantAdministration().then((value) => {
      if (!current) return;
      setState(value);
      setDraft(workspaceDraft(value));
    }).catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [api]);

  const original = state ? workspaceDraft(state) : null;
  const changes = original && draft ? (Object.keys(impacts) as Array<keyof WorkspaceDraft>)
    .filter((key) => original[key] !== draft[key]) : [];

  function updateDraft<K extends keyof WorkspaceDraft>(key: K, value: WorkspaceDraft[K]) {
    setDraft((current) => current && { ...current, [key]: value });
    setNotice(null);
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!state || !draft || !original || busy || changes.length === 0) return;
    setBusy(true);
    setError(null);
    try {
      const input = {
        name: draft.name.trim(),
        allow_audio_calls: draft.allow_audio_calls,
        allow_video_calls: draft.allow_video_calls,
        ...(draft.allow_calendar_export !== original.allow_calendar_export ? { allow_calendar_export: draft.allow_calendar_export } : {}),
        allow_public_channels: draft.allow_public_channels,
        message_edit_window_seconds: draft.message_edit_window_minutes === original.message_edit_window_minutes
          ? state.settings.message_edit_window_seconds
          : wholeUnits(draft.message_edit_window_minutes, 60, "Message edit window", 0, Math.max(2_592_000, state.settings.message_edit_window_seconds)),
        max_attachment_bytes: draft.max_attachment_mb === original.max_attachment_mb
          ? state.settings.max_attachment_bytes
          : wholeUnits(draft.max_attachment_mb, 1_000_000, "Attachment limit", 1, 1_073_741_824),
        default_retention_days: wholeUnits(draft.default_retention_days, 1, "Default retention", 1, 36500),
        max_active_users: wholeUnits(draft.max_active_users, 1, "Active identity limit", 1, 1_000_000),
        max_active_conversations: wholeUnits(draft.max_active_conversations, 1, "Active conversation limit", 1, 10_000_000),
        max_conversation_members: wholeUnits(draft.max_conversation_members, 1, "Conversation member limit", 2, 100_000),
        version: state.settings.version
      };
      const updated = await runWithStepUp(() => api.updateTenantAdministration(input));
      setState(updated);
      setDraft(workspaceDraft(updated));
      onUpdated(updated);
      setNotice("Workspace settings updated.");
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  if (!state || !draft || !original) return <section className="data-card"><div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading workspace settings…</div>{error && <div className="form-error" role="alert">{error}</div>}</section>;
  return <form className="data-card tenant-settings-form" onSubmit={(event) => void save(event)}>
    <div className="card-heading"><div><h2>Workspace settings</h2><p>Review workspace-wide communication, retention and capacity policies before saving.</p></div><span className="status-pill neutral">Version {state.settings.version}</span></div>
    {error && <div className="form-error" role="alert">{error}</div>}{notice && <div className="inline-notice" role="status">{notice}</div>}
    <fieldset disabled={busy} className="workspace-policy-group">
      <legend>Communication</legend>
      <p>Choose how members communicate and share files.</p>
      <div className="settings-grid form-grid">
        <label className="field">Workspace name<input name="name" value={draft.name} onChange={(event) => updateDraft("name", event.target.value)} required maxLength={120} /></label>
        <label className="field">Message edit window (minutes)<input name="message_edit_window_minutes" type="number" min={0} max={Math.max(43200, state.settings.message_edit_window_seconds / 60)} step="any" value={draft.message_edit_window_minutes} onChange={(event) => updateDraft("message_edit_window_minutes", event.target.value)} required /><small>0 prevents message editing. Fractions must represent whole seconds; 0.5 minutes is 30 seconds.</small></label>
        <label className="field">Attachment limit (MB)<input name="max_attachment_mb" type="number" min={0.000001} max={1073.741824} step="any" value={draft.max_attachment_mb} onChange={(event) => updateDraft("max_attachment_mb", event.target.value)} required /><small>1 MB = 1,000,000 bytes. Saved limit: {formatBytes(state.settings.max_attachment_bytes)}.</small></label>
      </div>
      <label className="checkbox-field"><input name="allow_audio_calls" type="checkbox" checked={draft.allow_audio_calls} onChange={(event) => updateDraft("allow_audio_calls", event.target.checked)} />Allow members to start and join audio calls</label>
      <label className="checkbox-field"><input name="allow_calendar_export" type="checkbox" checked={draft.allow_calendar_export} onChange={event => updateDraft("allow_calendar_export", event.target.checked)} />Allow explicit export of hosted meetings to connected calendars</label>
      <label className="checkbox-field"><input name="allow_video_calls" type="checkbox" checked={draft.allow_video_calls} onChange={(event) => updateDraft("allow_video_calls", event.target.checked)} />Allow members to start and join video calls</label>
      <label className="checkbox-field"><input name="allow_public_channels" type="checkbox" checked={draft.allow_public_channels} onChange={(event) => updateDraft("allow_public_channels", event.target.checked)} />Allow workspace-visible public channels</label>
    </fieldset>
    <fieldset disabled={busy} className="workspace-policy-group">
      <legend>Retention</legend>
      <label className="field">Default retention (days)<input name="default_retention_days" type="number" min={1} max={36500} value={draft.default_retention_days} onChange={(event) => updateDraft("default_retention_days", event.target.value)} required /><small>Applies where no explicit retention policy overrides it. Scheduled deletion respects legal holds.</small></label>
    </fieldset>
    <fieldset disabled={busy} className="workspace-policy-group quota-usage" aria-labelledby="quota-usage-title">
      <legend>Capacity</legend>
      <div className="card-heading"><h3 id="quota-usage-title">Capacity usage</h3><span className={`status-pill ${state.usage.over_limit.any ? "danger" : state.usage.at_capacity.any ? "neutral" : "success"}`}>{state.usage.over_limit.any ? "Over limit" : state.usage.at_capacity.any ? "At capacity" : "Within limits"}</span></div>
      {state.usage.over_limit.any && <div className="inline-notice error" role="alert">This workspace is over one or more admission limits. Existing data remains available, but new admissions are blocked until usage or limits are corrected.</div>}
      {!state.usage.over_limit.any && state.usage.at_capacity.any && <div className="inline-notice" role="status">One or more admission limits are at capacity. The next admission for a full category is blocked until usage falls or its limit increases.</div>}
      <div className="settings-grid form-grid">
        <label className="field">Maximum active identities<input name="max_active_users" type="number" min={1} max={1_000_000} value={draft.max_active_users} onChange={(event) => updateDraft("max_active_users", event.target.value)} required /><QuotaUsage current={state.usage.active_users} limit={state.usage.limits.max_active_users} over={state.usage.over_limit.active_users} draftLimit={draft.max_active_users} /><small>Human and service identities share this capacity.</small></label>
        <label className="field">Maximum active conversations<input name="max_active_conversations" type="number" min={1} max={10_000_000} value={draft.max_active_conversations} onChange={(event) => updateDraft("max_active_conversations", event.target.value)} required /><QuotaUsage current={state.usage.active_conversations} limit={state.usage.limits.max_active_conversations} over={state.usage.over_limit.active_conversations} draftLimit={draft.max_active_conversations} /><small>Archived conversations do not consume capacity.</small></label>
        <label className="field">Maximum members per conversation<input name="max_conversation_members" type="number" min={2} max={100_000} value={draft.max_conversation_members} onChange={(event) => updateDraft("max_conversation_members", event.target.value)} required /><QuotaUsage current={state.usage.largest_conversation_members} limit={state.usage.limits.max_conversation_members} over={state.usage.over_limit.conversation_members} draftLimit={draft.max_conversation_members} /><small>Usage shows the largest active conversation. Left memberships do not consume capacity.</small></label>
      </div>
    </fieldset>
    {changes.length > 0 && <section className="workspace-change-review" aria-label="Changes to review">
      <strong role="status">Unsaved changes · {changes.length} {changes.length === 1 ? "field" : "fields"}</strong>
      <ul>{changes.map((key) => <li key={key}><strong>{impacts[key].label}: {changeValue(original[key], impacts[key].unit)} → {changeValue(draft[key], impacts[key].unit)}</strong><span>{impacts[key].impact}</span></li>)}</ul>
    </section>}
    <div className="form-actions">
      <button className="button primary" type="submit" disabled={busy || changes.length === 0}>{busy ? "Saving…" : "Save workspace settings"}</button>
      {changes.length > 0 && <button className="button ghost" type="button" disabled={busy} onClick={() => { setDraft(original); setError(null); setNotice(null); }}>Discard changes</button>}
    </div>
  </form>;
}

function QuotaUsage({ current, limit, over, draftLimit }: { current: number; limit: number; over: boolean; draftLimit: string }) {
  const belowUsage = Number(draftLimit) < current;
  return <small className={`workspace-limit-usage ${over ? "quota-over" : ""}`}>
    <span>{current.toLocaleString()} of {limit.toLocaleString()}</span> currently used
    {belowUsage && draftLimit !== String(limit) && <span className="workspace-limit-impact">The proposed limit is below current usage. New admissions would be blocked until usage falls or the limit increases.</span>}
  </small>;
}
