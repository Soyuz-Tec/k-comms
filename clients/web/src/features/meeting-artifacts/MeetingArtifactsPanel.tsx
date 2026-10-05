import { useCallback, useEffect, useRef, useState } from "react";
import type { Room } from "livekit-client";
import type { MeetingArtifactsApi } from "../../api/domains/meeting-artifacts";
import { downloadUrl } from "../../api/uploads";
import { errorText } from "../../lib/format";
import type { MeetingArtifact, MeetingArtifactPage, MeetingArtifactSummary, TranscriptSegment } from "../../types/meeting-artifacts";
import { useLiveCaptions } from "./useLiveCaptions";
import "./MeetingArtifactsPanel.css";

export type MeetingCaptureStatus = "pending_consent" | "starting" | "recording" | "stopping" | null;
export function MeetingArtifactsPanel({ api, conversationId, callId, artifactId, joined = false, canManage = false, room = null, captureAllowed = true, onCaptureStatus }: {
  api: Partial<MeetingArtifactsApi>; conversationId: string; callId: string;
  artifactId?: string;
  joined?: boolean; canManage?: boolean; room?: Room | null; captureAllowed?: boolean;
  onCaptureStatus?: (status: MeetingCaptureStatus) => void;
}) {
  const [page, setPage] = useState<MeetingArtifactPage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [summaryRequested, setSummaryRequested] = useState(false);
  const [summary, setSummary] = useState<{ artifactId: string; value: MeetingArtifactSummary["summary"] } | null>(null);
  const [captionsEnabled, setCaptionsEnabled] = useState(false);
  const [transcript, setTranscript] = useState<{ artifactId: string; segments: TranscriptSegment[] } | null>(null);
  const [playback, setPlayback] = useState<{ artifactId: string; url: string } | null>(null);
  const generation = useRef(0);
  const playbackExpiry = useRef<ReturnType<typeof setTimeout> | null>(null);
  const operationId = useRef<string | null>(null);
  const focusedArtifact = useRef<HTMLLIElement | null>(null);
  const lastFocus = useRef<string | null>(null);
  const captions = useLiveCaptions(room, captionsEnabled && joined);
  const refresh = useCallback(async () => {
    if (!api.meetingArtifacts) return;
    const current = generation.current;
    try {
      const result = await api.meetingArtifacts(conversationId, callId);
      if (current !== generation.current) return;
      setPage(result); setError(null);
      setPlayback(value => result.data.some(item => item.id === value?.artifactId && item.status === "available") ? value : null);
      setSummary(value => result.data.some(item => item.id === value?.artifactId && item.status === "available") ? value : null);
      setTranscript(value => result.data.some(item => item.id === value?.artifactId && item.status === "available") ? value : null);
    } catch (reason) {
      if (current !== generation.current) return;
      setError(errorText(reason));
      // Content and signed URLs are cleared as soon as authorization cannot be revalidated.
      setTranscript(null); setPlayback(null); setSummary(null);
    }
  }, [api, callId, conversationId]);
  useEffect(() => {
    generation.current += 1;
    setPage(null); setSummaryRequested(false); setTranscript(null); setPlayback(null); setSummary(null); setCaptionsEnabled(false); setBusy(false); operationId.current = null;
    void refresh();
    const interval = setInterval(() => { if (document.visibilityState !== "hidden") void refresh(); }, 5_000);
    return () => { generation.current += 1; clearInterval(interval); if (playbackExpiry.current) clearTimeout(playbackExpiry.current); };
  }, [refresh]);
  const act = async (operation: () => Promise<unknown>) => {
    if (busy) return;
    const current = generation.current;
    setBusy(true); setError(null);
    try { await operation(); if (current === generation.current) await refresh(); }
    catch (reason) { if (current === generation.current) setError(errorText(reason)); }
    finally { if (current === generation.current) setBusy(false); }
  };
  const requestRecording = () => act(async () => {
    if (!api.requestRecording) return;
    operationId.current ??= crypto.randomUUID();
    if (summaryRequested) await api.requestRecording(conversationId, callId, operationId.current, true);
    else await api.requestRecording(conversationId, callId, operationId.current);
    operationId.current = null;
  });
  const openPlayback = (artifact: MeetingArtifact) => act(async () => {
    if (!api.artifactPlayback) return;
    const current = generation.current;
    const response = await api.artifactPlayback(conversationId, callId, artifact.id);
    const url = downloadUrl(response.download);
    if (!url) throw new Error("The recording storage address could not be verified.");
    if (current !== generation.current) return;
    setPlayback({ artifactId: artifact.id, url });
    if (playbackExpiry.current) clearTimeout(playbackExpiry.current);
    playbackExpiry.current = setTimeout(() => setPlayback(null), Math.min(response.download.expires_in ?? 60, 120) * 1_000);
  });
  const openTranscript = (artifact: MeetingArtifact) => act(async () => {
    if (!api.artifactTranscript) return;
    const current = generation.current;
    const response = await api.artifactTranscript(conversationId, callId, artifact.id);
    if (current === generation.current) setTranscript({ artifactId: artifact.id, segments: response.segments });
  });
  const openSummary = (artifact: MeetingArtifact) => act(async () => {
    if (!api.artifactSummary) return;
    const current = generation.current;
    const response = await api.artifactSummary(conversationId, callId, artifact.id);
    if (current === generation.current) setSummary({ artifactId: artifact.id, value: response.summary });
  });
  const active = page?.data.find(item => ["pending_consent", "starting", "recording", "stopping"].includes(item.status));
  const captureStatus = active?.status as MeetingCaptureStatus | undefined;
  useEffect(() => { onCaptureStatus?.(captureStatus ?? null); }, [captureStatus, onCaptureStatus]);
  useEffect(() => () => { onCaptureStatus?.(null); }, [onCaptureStatus]);
  const capability = page?.capabilities;
  const selectedArtifact = artifactId ? page?.data.find(item => item.id === artifactId && item.status !== "deleted") : undefined;
  useEffect(() => {
    const focusKey = `${conversationId}/${callId}/${artifactId}`;
    if (selectedArtifact && focusedArtifact.current && lastFocus.current !== focusKey) {
      focusedArtifact.current.focus();
      focusedArtifact.current.scrollIntoView?.({ block: "nearest" });
      lastFocus.current = focusKey;
    }
  }, [artifactId, callId, conversationId, selectedArtifact]);
  return <section className="meeting-artifacts" aria-label="Recording, captions and transcripts">
    <h3>Recording and captions</h3>
    {joined && <>
      <button type="button" aria-pressed={captionsEnabled} onClick={() => setCaptionsEnabled(enabled => !enabled)}>{captionsEnabled ? "Hide captions" : "Show captions"}</button>
      {captionsEnabled && <div className="meeting-live-captions" role="log" aria-live="polite" aria-label="Live captions">
        {captions.length ? captions.slice(-5).map(caption => <p key={caption.id}><strong>{caption.speaker}: </strong>{caption.text}</p>) : <p>Waiting for captions supplied by the meeting provider. Caption generation must be configured by your workspace.</p>}
        <small>Captions are local to this view and clear when hidden or when the call ends.</small>
      </div>}
    </>}
    {error && <p role="alert">{error} <button type="button" onClick={() => void refresh()}>Try again</button></p>}
    {!api.meetingArtifacts ? <p>Recording and saved transcripts are unavailable for this session.</p> : !page && !error ? <p role="status">Loading recording availability…</p> : null}
    {page && !capability?.recording && <p>{capability?.recording_reason === "guest_participant_only" ? "The host controls recording. Your explicit consent is required before capture." : "Recording is off. Workspace privacy approval, provider qualification and explicit participant consent are required."}</p>}
    {!captureAllowed && <p>Recording requires the LiveKit meeting transport.</p>}
    {canManage && joined && capability?.recording && !active && capability.explicit_summary && <label><input type="checkbox" checked={summaryRequested} disabled={busy} onChange={event => { setSummaryRequested(event.target.checked); operationId.current = null; }} />Request separately consented selected-quote summaries after this call</label>}
    {canManage && joined && capability?.recording && !active && <button type="button" disabled={busy || !captureAllowed || !api.requestRecording} onClick={() => void requestRecording()}>Request recording consent</button>}
    {active && <div className="meeting-recording-consent">
      <p role="status"><strong>{statusLabel(active.status)}</strong> · {active.consent_accepted_count}/{active.consent_required_count} participants consented</p>
      <p>This records meeting audio, video and shared screens. The workspace may generate a saved transcript using its approved service. Current conversation members can retrieve these artifacts until their retention deadline.</p>
      {joined && active.my_consent !== null && active.status !== "stopping" && <>
        {active.my_consent ? <button type="button" disabled={busy || !api.consentRecording} onClick={() => void act(() => api.consentRecording!(conversationId, callId, active.id, false))}>Withdraw consent and stop recording</button> : <>
          <button type="button" disabled={busy || !api.consentRecording} onClick={() => void act(() => api.consentRecording!(conversationId, callId, active.id, true))}>I consent to recording and transcription</button>
          <button type="button" disabled={busy || !api.consentRecording} onClick={() => void act(() => api.consentRecording!(conversationId, callId, active.id, false))}>Decline recording</button>
        </>}
      </>}
      {active.summary_requested && <div aria-label="Explicit summary consent">
        <p>This recording also requests a post-call summary consisting of selected, unchanged transcript quotes. Every capture admission must separately consent under meeting-summary-v1. Quotes remain restricted meeting content and expire with their source. You can withdraw consent; legal holds may retain restricted content.</p>
        <p>{active.summary_consent_accepted_count ?? 0}/{active.summary_consent_required_count ?? 0} admissions consented to summaries</p>
        {joined && active.my_summary_consent !== null && active.my_summary_consent !== undefined && active.status !== "stopping" && <>
          {active.my_summary_consent ? <button type="button" disabled={busy || !api.consentSummary} onClick={() => void act(() => api.consentSummary!(conversationId, callId, active.id, false))}>Withdraw summary consent and stop recording</button> : <>
            <button type="button" disabled={busy || !api.consentSummary} onClick={() => void act(() => api.consentSummary!(conversationId, callId, active.id, true))}>I separately consent to selected-quote summaries</button>
            <button type="button" disabled={busy || !api.consentSummary} onClick={() => void act(() => api.consentSummary!(conversationId, callId, active.id, false))}>Decline summaries</button>
          </>}
        </>}
      </div>}
      {active.can_manage && active.status === "pending_consent" && <button type="button" disabled={busy || !captureAllowed || active.consent_accepted_count !== active.consent_required_count || (active.summary_requested && active.summary_consent_accepted_count !== active.summary_consent_required_count) || !api.startRecording} onClick={() => void act(() => api.startRecording!(conversationId, callId, active.id))}>Start recording</button>}
      {active.can_manage && active.status !== "stopping" && <button type="button" disabled={busy || !api.stopRecording} onClick={() => void act(() => api.stopRecording!(conversationId, callId, active.id))}>{active.status === "pending_consent" ? "Cancel recording request" : "Stop recording"}</button>}
      {active.status === "stopping" && <p>Stop requested. The indicator stays visible until the provider confirms capture has ended.</p>}
    </div>}
    <h4>Saved recordings and transcripts</h4>
    {capability?.recognition_mode === "post_recording" && <small>Recognition produces saved transcripts after recording. Selected-quote summaries require separate disclosed consent and an ended call.</small>}
    {page && artifactId && !selectedArtifact && <p role="alert">The linked recording or transcript is unavailable. It may have expired, been deleted, or changed access.</p>}
    {page && page.data.filter(item => item !== active).length === 0 && <p>No saved artifacts for this call.</p>}
    <ul>{page?.data.filter(item => item !== active && item.status !== "deleted").map(artifact => <li key={artifact.id} ref={artifact.id === artifactId ? focusedArtifact : undefined} tabIndex={artifact.id === artifactId ? -1 : undefined} data-selected={artifact.id === artifactId || undefined}>
      <strong>{artifact.kind === "recording" ? "Recording" : artifact.kind === "summary" ? "Selected-quote summary" : "Post-recording transcript"}</strong> · <span>{statusLabel(artifact.status)}</span>
      <small>Created {new Date(artifact.created_at).toLocaleString()} · Retained until {new Date(artifact.expires_at).toLocaleDateString()}</small>
      {artifact.status === "failed" && artifact.failure_code && <small>{failureMessage(artifact.failure_code)}</small>}
      {artifact.status === "available" && artifact.kind === "recording" && <button type="button" disabled={busy || !api.artifactPlayback} onClick={() => void openPlayback(artifact)}>Play recording</button>}
      {artifact.status === "available" && artifact.kind === "recording" && artifact.can_manage && capability?.persistent_transcript && !page.data.some(item => item.source_artifact_id === artifact.id && item.status !== "deleted" && item.status !== "failed") && <button type="button" disabled={busy || !api.requestTranscript} onClick={() => void act(() => api.requestTranscript!(conversationId, callId, artifact.id, crypto.randomUUID()))}>Generate transcript</button>}
      {artifact.status === "available" && artifact.kind === "transcript" && <button type="button" disabled={busy || !api.artifactTranscript} onClick={() => void openTranscript(artifact)}>Read transcript</button>}
      {artifact.kind === "recording" && artifact.summary_requested && (artifact.my_summary_consent || artifact.can_withdraw_summary_consent) && <button type="button" disabled={busy || !api.consentSummary} onClick={() => void act(() => api.consentSummary!(conversationId, callId, artifact.id, false))}>Withdraw retained summary consent</button>}
      {artifact.status === "available" && artifact.kind === "transcript" && artifact.summary_request_available === true && artifact.can_manage && capability?.explicit_summary && !page.data.some(item => item.kind === "summary" && item.source_artifact_id === artifact.id) && <button type="button" disabled={busy || !api.requestSummary} onClick={() => void act(() => api.requestSummary!(conversationId, callId, artifact.id, crypto.randomUUID()))}>Select summary quotes after the call</button>}
      {artifact.status === "available" && artifact.kind === "summary" && <button type="button" disabled={busy || !api.artifactSummary} onClick={() => void openSummary(artifact)}>Read selected-quote summary</button>}
      {artifact.can_manage && ["available", "failed"].includes(artifact.status) && <button type="button" disabled={busy || !api.deleteMeetingArtifact} onClick={() => void act(() => api.deleteMeetingArtifact!(conversationId, callId, artifact.id))}>Delete {artifact.kind}</button>}
      {playback?.artifactId === artifact.id && <div><video controls preload="none" src={playback.url} aria-label="Meeting recording" /><button type="button" onClick={() => setPlayback(null)}>Close recording</button></div>}
      {summary?.artifactId === artifact.id && <div role="region" aria-label="Selected-quote summary"><p>Method: selected unchanged transcript quotes; no generated facts. Source transcript {summary.value.source_artifact_id}.</p><p style={{ whiteSpace: "pre-wrap" }}>{summary.value.text}</p><small>Source SHA-256: {summary.value.source_sha256}</small><button type="button" onClick={() => setSummary(null)}>Close summary</button></div>}
      {transcript?.artifactId === artifact.id && <div className="meeting-saved-transcript" role="region" aria-label="Saved transcript">{transcript.segments.map(segment => <p key={segment.sequence}><time>{formatTime(segment.start_ms)}</time> {segment.text}</p>)}<button type="button" onClick={() => setTranscript(null)}>Close transcript</button></div>}
    </li>)}</ul>
    {page && !capability?.persistent_transcript && <small>Saved transcription is off until a qualified transcription service is explicitly enabled.</small>}
  </section>;
}

function statusLabel(status: MeetingArtifact["status"]) {
  const labels: Record<MeetingArtifact["status"], string> = { pending_consent: "Waiting for recording consent", starting: "Starting recording", recording: "Recording is active", stopping: "Stopping recording", processing: "Processing and verifying", available: "Available", failed: "Failed or cancelled", deleting: "Deletion queued", deleted: "Deleted" };
  return labels[status];
}
function formatTime(ms: number) { const seconds = Math.floor(ms / 1_000); return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`; }
function failureMessage(code: string) {
  if (code === "cancelled") return "The recording request was cancelled.";
  if (code === "provider_failed") return "The meeting provider could not complete this recording.";
  if (code === "transcription_source_or_result_invalid") return "The transcription service could not process this recording within its approved format and size limits.";
  if (code === "transcription_authorization_changed") return "Transcription stopped because its approval or retention deadline changed.";
  return "This artifact could not be completed. Your workspace administrator can review its processing status.";
}
