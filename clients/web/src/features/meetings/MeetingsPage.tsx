import { useEffect, useId, useMemo, useRef, useState, type FormEvent } from "react";
import { createPortal } from "react-dom";
import { Link, useSearchParams } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { ConfirmDialog } from "../../components/ActionDialog";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { useModalDialog } from "../../components/useModalDialog";
import { conversationTitle, errorText } from "../../lib/format";
import type { Conversation } from "../../types";
import type { Meeting, MeetingInput, MeetingOccurrence } from "../../types/meetings";
import { useCallSession } from "../calls/CallSessionProvider";
import { dateInTimezone, meetingInput, monthDays, monthQuery, systemTimezone, validateMeeting } from "./meetingCalendar";
import "./meetings.css";
import { MeetingCalendarExport } from "../calendar-sync/MeetingCalendarExport";

interface OccurrenceRow {
  meeting: Meeting;
  occurrence: MeetingOccurrence;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function MeetingsPage() {
  const { api, session } = useSession();
  const { conversations, capabilities, audioCallsAvailable, videoCallsAvailable, loading: workspaceLoading } = useWorkspaceData();
  const { launchCall } = useCallSession();
  const [params, setParams] = useSearchParams();
  const requestedMeeting = params.get("meeting");
  const requestedOccurrence = params.get("occurrence");
  const [linkedMeeting, setLinkedMeeting] = useState<Meeting | null>(null);
  const [linkedOccurrence, setLinkedOccurrence] = useState<string | null>(null);
  const [linkLoading, setLinkLoading] = useState(false);
  const [linkError, setLinkError] = useState<string | null>(null);
  const linkGeneration = useRef(0);
  const [timezone] = useState(systemTimezone);
  const [month, setMonth] = useState(() => dateInTimezone(new Date().toISOString(), timezone).slice(0, 7));
  const [view, setView] = useState<"list" | "calendar">("list");
  const [selectedDay, setSelectedDay] = useState<string | null>(null);
  const [meetings, setMeetings] = useState<Meeting[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [editor, setEditor] = useState<Meeting | "new" | null>(null);
  const [cancelling, setCancelling] = useState<Meeting | null>(null);
  const [saving, setSaving] = useState(false);
  const [downloadingId, setDownloadingId] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const generation = useRef(0);
  const query = useMemo(() => monthQuery(month, timezone), [month, timezone]);
  const activeConversations = conversations.filter((conversation) => !conversation.archived_at);
  const conversationById = new Map(conversations.map((conversation) => [conversation.id, conversation]));
  const videoEnabled = !workspaceLoading && capabilities?.allow_video_calls === true && videoCallsAvailable;
  const audioEnabled = !workspaceLoading && capabilities?.allow_audio_calls === true && audioCallsAvailable;
  const meetingKind = videoEnabled ? "video" : "audio";

  useEffect(() => {
    const requestGeneration = ++generation.current;
    setLoading(true);
    setLoadError(null);
    void api.meetings(query).then((next) => {
      if (requestGeneration === generation.current) setMeetings(next);
    }).catch((reason: unknown) => {
      if (requestGeneration === generation.current) setLoadError(errorText(reason));
    }).finally(() => {
      if (requestGeneration === generation.current) setLoading(false);
    });
    return () => { generation.current += 1; };
  }, [api, query, refresh]);

  useEffect(() => {
    const generation = ++linkGeneration.current;
    setLinkedMeeting(null); setLinkedOccurrence(null); setLinkError(null); setLinkLoading(false);
    if (!requestedMeeting && !requestedOccurrence) return;
    if (!requestedMeeting || !uuid.test(requestedMeeting) || (requestedOccurrence && !uuid.test(requestedOccurrence))) {
      setLinkError("This meeting link is incomplete or invalid. Open a meeting from your calendar or workspace search.");
      return;
    }
    setLinkLoading(true);
    void api.getMeeting(requestedMeeting).then(meeting => {
      if (generation !== linkGeneration.current) return;
      if (meeting.id.toLowerCase() !== requestedMeeting.toLowerCase()) throw new Error("The requested meeting could not be verified.");
      const occurrence = requestedOccurrence
        ? meeting.occurrences.find(item => item.id.toLowerCase() === requestedOccurrence.toLowerCase())
        : meeting.occurrences.find(item => Date.parse(item.ends_at) > Date.now()) || meeting.occurrences[0];
      if (!occurrence) throw new Error("The selected meeting occurrence is unavailable.");
      const day = dateInTimezone(occurrence.starts_at, timezone);
      setMonth(day.slice(0, 7)); setSelectedDay(day); setView("list");
      setLinkedMeeting(meeting); setLinkedOccurrence(occurrence.id);
    }).catch((reason: unknown) => {
      if (generation === linkGeneration.current) setLinkError(errorText(reason));
    }).finally(() => {
      if (generation === linkGeneration.current) setLinkLoading(false);
    });
    return () => { linkGeneration.current += 1; };
  }, [api, requestedMeeting, requestedOccurrence, timezone, refresh]);

  const rows = useMemo(() => (linkedMeeting ? [...meetings.filter(meeting => meeting.id !== linkedMeeting.id), linkedMeeting] : meetings).flatMap((meeting) => meeting.occurrences
    .filter((occurrence) => Date.parse(occurrence.starts_at) >= Date.parse(query.from) && Date.parse(occurrence.starts_at) < Date.parse(query.to))
    .map((occurrence) => ({ meeting, occurrence })))
    .sort((left, right) => left.occurrence.starts_at.localeCompare(right.occurrence.starts_at)), [meetings, linkedMeeting, query]);
  const visibleRows = selectedDay
    ? rows.filter(({ occurrence }) => dateInTimezone(occurrence.starts_at, timezone) === selectedDay)
    : rows;
  const upcomingRows = rows.filter(({ meeting, occurrence }) => meeting.status !== "cancelled" && occurrence.status !== "cancelled" && Date.parse(occurrence.ends_at) > Date.now());
  const nextMeeting = upcomingRows[0];
  const inProgressCount = upcomingRows.filter(({ occurrence }) => Date.parse(occurrence.starts_at) <= Date.now()).length;
  const nextInProgress = Boolean(nextMeeting && Date.parse(nextMeeting.occurrence.starts_at) <= Date.now());
  const showNextSummary = Boolean(nextMeeting && (view === "calendar" || !visibleRows.some(({ occurrence }) => occurrence.id === nextMeeting.occurrence.id)));
  const nextAgendaIndex = nextMeeting ? visibleRows.findIndex(({ occurrence }) => occurrence.id === nextMeeting.occurrence.id) : -1;

  function focusNextMeeting() {
    if (!nextMeeting) return;
    setView("list");
    setSelectedDay(null);
    window.requestAnimationFrame(() => document.getElementById(`meeting-${nextMeeting.occurrence.id}`)?.focus());
  }

  if (!session) return null;

  async function saveMeeting(conversationId: string, input: MeetingInput) {
    setSaving(true);
    setActionError(null);
    try {
      if (editor && editor !== "new") {
        await api.updateMeeting(editor.id, { ...input, expected_version: editor.version });
      } else {
        await api.createMeeting(conversationId, input);
      }
      setEditor(null);
      setNotice(editor === "new" ? "Meeting scheduled." : "Meeting updated.");
      setRefresh((value) => value + 1);
    } catch (reason: unknown) {
      setActionError(errorText(reason));
    } finally {
      setSaving(false);
    }
  }

  async function cancelMeeting() {
    if (!cancelling) return;
    setSaving(true);
    setActionError(null);
    try {
      await api.cancelMeeting(cancelling.id, cancelling.version);
      setCancelling(null);
      setNotice("Meeting cancelled. Download the updated invitation to update your calendar.");
      setRefresh((value) => value + 1);
    } catch (reason: unknown) {
      setActionError(errorText(reason));
    } finally {
      setSaving(false);
    }
  }

  async function downloadInvitation(meeting: Meeting) {
    setDownloadingId(meeting.id);
    setActionError(null);
    try {
      const ics = await api.meetingCalendar(meeting.id);
      const url = URL.createObjectURL(new Blob([ics], { type: "text/calendar;charset=utf-8" }));
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = `meeting-${meeting.id}.ics`;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
    } catch (reason: unknown) {
      setActionError(errorText(reason));
    } finally {
      setDownloadingId(null);
    }
  }

  function launchMeeting(meeting: Meeting, occurrence: MeetingOccurrence) {
    const conversation = conversationById.get(meeting.conversation_id);
    if (!conversation) return;
    launchCall(conversation, meetingKind, null, { meetingId: meeting.id, occurrenceId: occurrence.id });
  }

  return <main className="meetings-page member-page" id="main-content">
    <SurfaceHeader title="Meetings" description="See what is next and schedule time with your conversations." actions={<>
      <Link className="button ghost" to="/app/artifacts">Recordings</Link>
      <Link className="button ghost" to="/app/you?section=calendar">Connected calendars</Link>
      <button className="button primary" type="button" disabled={workspaceLoading || activeConversations.length === 0} onClick={() => { setEditor("new"); setActionError(null); }}>Schedule meeting</button>
    </>} />
    {!workspaceLoading && activeConversations.length === 0 && <p role="note">Create or join a conversation in <Link to="/app/">Inbox</Link> to schedule a meeting.</p>}
    <div className="meetings-toolbar">
      <label className="field">Month<input type="month" value={month} onChange={(event) => { if (/^\d{4}-\d{2}$/.test(event.target.value)) { setMonth(event.target.value); setSelectedDay(null); } }} /></label>
      <div className="member-segmented-control" role="group" aria-label="Meeting view">
        <button type="button" aria-pressed={view === "list"} onClick={() => { setView("list"); setSelectedDay(null); }}>Agenda</button>
        <button type="button" aria-pressed={view === "calendar"} onClick={() => setView("calendar")}>Calendar</button>
      </div>
      <span>Calendar time zone: {timezone}</span>
      {!loading && !loadError && nextMeeting && <span className="status-pill neutral">{inProgressCount > 0 && `${inProgressCount} in progress · `}{upcomingRows.length - inProgressCount} upcoming this month</span>}
      {!loading && !loadError && !showNextSummary && nextAgendaIndex > 0 && <button className="button ghost" type="button" onClick={focusNextMeeting}>{nextInProgress ? "View current meeting" : "View next meeting"}</button>}
      <button className="button ghost" type="button" disabled={loading} onClick={() => setRefresh((value) => value + 1)}>Refresh meetings</button>
    </div>
    {notice && <p className="inline-notice" role="status">{notice}</p>}
    {linkLoading && <p role="status">Opening the selected meeting…</p>}
    {linkError && <p className="inline-notice error" role="alert">{linkError}</p>}
    {linkedMeeting && <p className="inline-notice" role="status">Selected meeting: {linkedMeeting.title} <button className="button ghost compact" type="button" onClick={() => { const next = new URLSearchParams(params); next.delete("meeting"); next.delete("occurrence"); setParams(next); setSelectedDay(null); }}>Show all meetings</button></p>}
    {actionError && !editor && !cancelling && <p className="inline-notice error" role="alert">{actionError}</p>}
    {loadError && <div className="inline-notice error" role="alert"><span>{loadError}</span><button type="button" onClick={() => setRefresh((value) => value + 1)}>Try again</button></div>}
    {loading ? <p className="member-status-view" role="status">Loading meetings…</p> : !loadError && <>
      {showNextSummary && nextMeeting && <section className="meetings-next surface-card" aria-labelledby="meetings-next-heading">
        <div><h2 id="meetings-next-heading">{nextInProgress ? "In progress" : "Up next"}</h2><strong>{nextMeeting.meeting.title}</strong><p><time dateTime={nextMeeting.occurrence.starts_at}>{formatMeetingTime(nextMeeting.occurrence.starts_at, timezone)}</time> · {nextMeeting.meeting.duration_minutes} minutes</p>{nextInProgress && <p>The scheduled meeting time is underway.</p>}</div>
        <div className="meetings-next-actions"><button className="button ghost" type="button" onClick={focusNextMeeting}>{nextInProgress ? "View current meeting" : "View next meeting"}</button></div>
      </section>}
      {view === "calendar" && <MeetingCalendar month={month} timezone={timezone} rows={rows} selectedDay={selectedDay} onSelect={setSelectedDay} />}
      {selectedDay && <div className="meetings-day-heading"><h2>Meetings on {selectedDay}</h2><button className="button ghost" type="button" onClick={() => setSelectedDay(null)}>Show all days</button></div>}
      {visibleRows.length === 0 ? <div className="surface-empty"><strong>{selectedDay ? "No meetings on this day." : "No meetings scheduled this month."}</strong><p>Schedule a meeting with an existing conversation or choose another month.</p></div> : <ol className="meetings-list" aria-label="Scheduled meetings">
        {visibleRows.map(({ meeting, occurrence }) => {
          const conversation = conversationById.get(meeting.conversation_id);
          const cancelled = meeting.status === "cancelled" || occurrence.status === "cancelled";
          const ended = Date.parse(occurrence.ends_at) <= Date.now();
          const joinWindowOpen = Date.parse(occurrence.starts_at) <= Date.now() + 15 * 60_000;
          const waitingForHost = meeting.host_user_id !== session.user.id && !meeting.host_policy.join_before_host && !occurrence.call_id;
          const canJoin = !cancelled && !ended && joinWindowOpen && !waitingForHost && (videoEnabled || audioEnabled) && Boolean(conversation);
          return <li id={`meeting-${occurrence.id}`} tabIndex={-1} className={`meeting-row${cancelled ? " cancelled" : ""}${nextMeeting?.occurrence.id === occurrence.id ? " is-next" : ""}`} aria-current={linkedMeeting?.id === meeting.id && linkedOccurrence === occurrence.id ? "true" : undefined} key={occurrence.id}>
            <div className="meeting-row-copy">
              <h2>{meeting.title}</h2>
              {nextMeeting?.occurrence.id === occurrence.id && <span className="status-pill neutral">{nextInProgress ? "In progress" : "Next meeting"}</span>}
              <p><time dateTime={occurrence.starts_at}>{formatMeetingTime(occurrence.starts_at, meeting.timezone)}</time><span> · {meeting.duration_minutes} minutes</span></p>
              <p>{conversation ? conversationTitle(conversation) : "Conversation unavailable"} · {meeting.timezone}</p>
              {meeting.recurrence.frequency !== "none" && <p>Repeats every {meeting.recurrence.interval} {meeting.recurrence.frequency === "daily" ? "day(s)" : "week(s)"}, {meeting.recurrence.count} times</p>}
              <p className="meeting-policy">{meeting.host_policy.allow_guests ? "Guests allowed" : "Members only"} · {meeting.host_policy.join_before_host ? "Join before host allowed" : "Host must join first"}</p>
              {!cancelled && !ended && !joinWindowOpen && <p className="meeting-policy">The lobby opens 15 minutes before the meeting.</p>}
              {!cancelled && !ended && joinWindowOpen && waitingForHost && <p className="meeting-policy">Waiting for the host. Refresh meetings after the host joins.</p>}
              {cancelled && <strong className="meeting-status">Cancelled</strong>}
              {ended && !cancelled && <span className="meeting-status">Ended</span>}
              {meeting.host_user_id === session.user.id && <MeetingCalendarExport meeting={meeting} />}
            </div>
            <div className="meeting-row-actions">
              {conversation && <Link className="button ghost compact" to={`/app/?${new URLSearchParams({ conversation: conversation.id }).toString()}`}>Open conversation</Link>}
              {!cancelled && !ended && <button className="button primary compact" type="button" disabled={!canJoin} title={!joinWindowOpen ? "The lobby opens 15 minutes before the meeting." : waitingForHost ? "Waiting for the host to join." : canJoin ? `Open ${meetingKind} meeting lobby` : "Calling is unavailable. Check availability from Calls."} onClick={() => launchMeeting(meeting, occurrence)}>{meeting.host_user_id === session.user.id ? "Start meeting" : "Join meeting"}</button>}
              <button className="button ghost compact" type="button" disabled={downloadingId === meeting.id} onClick={() => void downloadInvitation(meeting)}>{downloadingId === meeting.id ? "Downloading…" : "Download invitation"}</button>
              {meeting.can_manage && !cancelled && <>
                <button className="button ghost compact" type="button" onClick={() => { setEditor(meeting); setActionError(null); }}>Edit {meeting.recurrence.count > 1 ? "series" : "meeting"}</button>
                <button className="button ghost compact" type="button" onClick={() => { setCancelling(meeting); setActionError(null); }}>Cancel {meeting.recurrence.count > 1 ? "series" : "meeting"}</button>
              </>}
            </div>
          </li>;
        })}
      </ol>}
    </>}
    {editor && <MeetingEditor key={editor === "new" ? "new" : `${editor.id}:${editor.version}`} meeting={editor === "new" ? undefined : editor} conversations={activeConversations} busy={saving} error={actionError} onClose={() => { if (!saving) { setEditor(null); setActionError(null); } }} onSave={saveMeeting} />}
    {cancelling && <ConfirmDialog title="Cancel meeting?" description={`Cancel ${cancelling.title}${cancelling.recurrence.count > 1 ? " and every occurrence in this series" : ""}?`} impact="Members will see the cancellation. Download and share the updated invitation to update external calendars." confirmLabel="Cancel meeting" cancelLabel="Keep meeting" tone="danger" busy={saving} error={actionError} onCancel={() => { setCancelling(null); setActionError(null); }} onConfirm={() => void cancelMeeting()} />}
  </main>;
}

function formatMeetingTime(instant: string, timezone: string): string {
  return new Intl.DateTimeFormat(undefined, { timeZone: timezone, dateStyle: "medium", timeStyle: "short" }).format(new Date(instant));
}

function MeetingCalendar({ month, timezone, rows, selectedDay, onSelect }: {
  month: string;
  timezone: string;
  rows: OccurrenceRow[];
  selectedDay: string | null;
  onSelect: (day: string) => void;
}) {
  const byDay = new Map<string, OccurrenceRow[]>();
  for (const row of rows) {
    const day = dateInTimezone(row.occurrence.starts_at, timezone);
    byDay.set(day, [...(byDay.get(day) || []), row]);
  }
  return <section className="meetings-calendar" aria-label={`${month} meeting calendar`}>
    <div className="meetings-calendar-weekdays" aria-hidden="true">{["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((day) => <span key={day}>{day}</span>)}</div>
    <div className="meetings-calendar-days">
      {monthDays(month).map((day, index) => day ? <button type="button" key={day} className="meetings-calendar-day" aria-pressed={selectedDay === day} aria-label={`${day}, ${(byDay.get(day) || []).length} meetings`} onClick={() => onSelect(day)}>
        <strong>{Number(day.slice(-2))}</strong>
        {(byDay.get(day) || []).slice(0, 3).map(({ meeting, occurrence }) => <span key={occurrence.id} className={meeting.status === "cancelled" ? "cancelled" : ""}>{new Intl.DateTimeFormat(undefined, { timeZone: timezone, hour: "numeric", minute: "2-digit" }).format(new Date(occurrence.starts_at))} {meeting.title}</span>)}
        {(byDay.get(day) || []).length > 3 && <small>+{(byDay.get(day) || []).length - 3} more</small>}
      </button> : <div className="meetings-calendar-blank" key={`blank-${index}`} />)}
    </div>
  </section>;
}

function MeetingEditor({ meeting, conversations, busy, error, onClose, onSave }: {
  meeting?: Meeting;
  conversations: Conversation[];
  busy: boolean;
  error: string | null;
  onClose: () => void;
  onSave: (conversationId: string, input: MeetingInput) => Promise<void>;
}) {
  const dialogRef = useModalDialog(onClose);
  const formId = useId();
  const [conversationId, setConversationId] = useState(meeting?.conversation_id || "");
  const [input, setInput] = useState<MeetingInput>(() => meeting ? meetingInput(meeting) : {
    title: "", timezone: systemTimezone(), local_start: "", duration_minutes: 30,
    recurrence: { frequency: "none", interval: 1, count: 1 }, reminder_minutes: 15,
    host_policy: { allow_guests: false, join_before_host: false }
  });
  const [validation, setValidation] = useState<string | null>(null);
  function change<T extends keyof MeetingInput>(field: T, value: MeetingInput[T]) {
    setInput((current) => ({ ...current, [field]: value }));
    setValidation(null);
  }
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!meeting && !conversations.some((conversation) => conversation.id === conversationId)) {
      setValidation("Choose a conversation for the meeting.");
      return;
    }
    const next = {
      ...input, title: input.title.trim(), timezone: input.timezone.trim(),
      recurrence: input.recurrence.frequency === "none" ? { frequency: "none" as const, interval: 1, count: 1 } : input.recurrence
    };
    const failure = validateMeeting(next);
    if (failure) { setValidation(failure); return; }
    void onSave(conversationId, next);
  }
  return createPortal(<div className="modal-backdrop"><section ref={dialogRef} className="modal-dialog meeting-editor" role="dialog" aria-modal="true" aria-labelledby="meeting-editor-title" tabIndex={-1}>
    <header className="app-dialog-heading"><h2 id="meeting-editor-title">{meeting ? "Edit meeting" : "Schedule meeting"}</h2><button className="button ghost compact" type="button" disabled={busy} onClick={onClose}>Close</button></header>
    <form onSubmit={submit}>
      <fieldset disabled={busy}>
        <label className="field">Title<input data-initial-focus required maxLength={200} value={input.title} onChange={(event) => change("title", event.target.value)} /></label>
        <label className="field"><span id={`${formId}-conversation`}>Conversation</span><select aria-labelledby={`${formId}-conversation`} required disabled={Boolean(meeting)} value={conversationId} onChange={(event) => setConversationId(event.target.value)}><option value="">Choose a conversation</option>{meeting && !conversations.some((conversation) => conversation.id === meeting.conversation_id) && <option value={meeting.conversation_id}>Meeting conversation</option>}{conversations.map((conversation) => <option key={conversation.id} value={conversation.id}>{conversationTitle(conversation)}</option>)}</select></label>
        <div className="meeting-form-grid">
          <label className="field">Local start date and time<input type="datetime-local" required value={input.local_start} onChange={(event) => change("local_start", event.target.value)} /></label>
          <label className="field"><span id={`${formId}-timezone`}>Time zone</span><input aria-labelledby={`${formId}-timezone`} required list="meeting-timezones" value={input.timezone} onChange={(event) => change("timezone", event.target.value)} placeholder="America/New_York" /><datalist id="meeting-timezones">{[...new Set([systemTimezone(), "UTC", "America/New_York", "America/Los_Angeles", "Europe/London", "Europe/Berlin", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney"])].map((zone) => <option key={zone} value={zone} />)}</datalist></label>
          <label className="field">Duration (minutes)<input type="number" required min={5} max={480} step={1} value={input.duration_minutes} onChange={(event) => change("duration_minutes", Number(event.target.value))} /></label>
          <label className="field"><span id={`${formId}-repeat`}>Repeat</span><select aria-labelledby={`${formId}-repeat`} value={input.recurrence.frequency} onChange={(event) => change("recurrence", { ...input.recurrence, frequency: event.target.value as MeetingInput["recurrence"]["frequency"] })}><option value="none">Does not repeat</option><option value="daily">Daily</option><option value="weekly">Weekly</option></select></label>
          {input.recurrence.frequency !== "none" && <>
            <label className="field">Repeat every {input.recurrence.frequency === "daily" ? "days" : "weeks"}<input type="number" required min={1} max={4} step={1} value={input.recurrence.interval} onChange={(event) => change("recurrence", { ...input.recurrence, interval: Number(event.target.value) })} /></label>
            <label className="field">Number of occurrences<input type="number" required min={1} max={52} step={1} value={input.recurrence.count} onChange={(event) => change("recurrence", { ...input.recurrence, count: Number(event.target.value) })} /></label>
          </>}
        </div>
        <p className="meeting-form-help">Times follow this time zone, including daylight saving changes. Schedule at least a minute ahead. Repeating meetings must finish within the next year.</p>
        <label className="field">Reminder (minutes before start)<input type="number" min={0} max={10080} step={1} required value={input.reminder_minutes} onChange={(event) => change("reminder_minutes", Number(event.target.value))} aria-describedby="meeting-reminder-help" /><small id="meeting-reminder-help">From 0 to 10080 minutes. Use 0 for a reminder at the start.</small></label>
        <label className="meeting-checkbox"><input type="checkbox" checked={input.host_policy.allow_guests} onChange={(event) => change("host_policy", { ...input.host_policy, allow_guests: event.target.checked })} />Allow guests</label>
        <label className="meeting-checkbox"><input type="checkbox" checked={input.host_policy.join_before_host} onChange={(event) => change("host_policy", { ...input.host_policy, join_before_host: event.target.checked })} />Allow joining before the host</label>
      </fieldset>
      {(validation || error) && <p className="form-error" role="alert">{validation || error}</p>}
      <div className="form-actions"><button className="button ghost" type="button" disabled={busy} onClick={onClose}>Cancel</button><button className="button primary" type="submit" disabled={busy}>{busy ? "Saving…" : meeting ? "Save changes" : "Schedule meeting"}</button></div>
    </form>
  </section></div>, document.body);
}
