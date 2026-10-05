import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { RoomEvent, type Room } from "livekit-client";
import type { MeetingArtifact, MeetingArtifactPage } from "../../types/meeting-artifacts";
import type { MeetingArtifactsApi } from "../../api/domains/meeting-artifacts";
import { MeetingArtifactsPanel } from "./MeetingArtifactsPanel";

const recording: MeetingArtifact = { id: "recording-1", call_id: "call-1", conversation_id: "conversation-1", kind: "recording", status: "pending_consent", created_at: "2026-10-04T12:00:00Z", expires_at: "2026-11-04T12:00:00Z", consent_required_count: 2, consent_accepted_count: 0, my_consent: false, can_manage: true, content_type: "video/mp4" };
function page(data: MeetingArtifact[], enabled = true): MeetingArtifactPage { return { data, capabilities: { recording: enabled, recording_reason: "privacy_opt_in_required", participant_consent_required: true, persistent_transcript: enabled, persistent_transcript_reason: "qualified_provider_required", captions: "provider_events_only", automatic_capture: false } }; }
function api(response: MeetingArtifactPage): MeetingArtifactsApi {
  return { meetingArtifacts: vi.fn().mockResolvedValue(response), requestRecording: vi.fn().mockResolvedValue(recording), requestTranscript: vi.fn().mockResolvedValue(recording), requestSummary: vi.fn().mockResolvedValue(recording), consentSummary: vi.fn().mockResolvedValue(recording), artifactSummary: vi.fn(), consentRecording: vi.fn().mockResolvedValue(recording), startRecording: vi.fn().mockResolvedValue(recording), stopRecording: vi.fn().mockResolvedValue(recording), artifactPlayback: vi.fn(), artifactTranscript: vi.fn(), deleteMeetingArtifact: vi.fn().mockResolvedValue(recording) };
}

describe("meeting artifacts", () => {
  it("defaults captions and recording off, and explains the real provider gates", async () => {
    const client = api(page([], false));
    render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" joined canManage />);
    expect(await screen.findByText(/Recording is off/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Show captions" })).toHaveAttribute("aria-pressed", "false");
    expect(screen.queryByRole("button", { name: "Request recording consent" })).not.toBeInTheDocument();
    expect(client.requestRecording).not.toHaveBeenCalled();
    expect(client.startRecording).not.toHaveBeenCalled();
  });

  it("requires every participant's explicit consent and persists the user's actual choice", async () => {
    const client = api(page([recording]));
    render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" joined canManage />);
    expect(await screen.findByRole("button", { name: "Start recording" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "I consent to recording and transcription" }));
    await waitFor(() => expect(client.consentRecording).toHaveBeenCalledWith("conversation-1", "call-1", "recording-1", true));
    expect(client.startRecording).not.toHaveBeenCalled();
    await waitFor(() => expect(screen.getByRole("button", { name: "Decline recording" })).toBeEnabled());
    fireEvent.click(screen.getByRole("button", { name: "Decline recording" }));
    await waitFor(() => expect(client.consentRecording).toHaveBeenLastCalledWith("conversation-1", "call-1", "recording-1", false));
  });

  it("starts only after all consent and keeps stopping visible until provider confirmation", async () => {
    const client = api(page([{ ...recording, consent_accepted_count: 2, my_consent: true }]));
    const rendered = render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" joined canManage />);
    fireEvent.click(await screen.findByRole("button", { name: "Start recording" }));
    await waitFor(() => expect(client.startRecording).toHaveBeenCalledWith("conversation-1", "call-1", "recording-1"));
    const stopping = api(page([{ ...recording, status: "stopping", my_consent: true, consent_accepted_count: 2 }]));
    rendered.rerender(<MeetingArtifactsPanel api={stopping} conversationId="conversation-1" callId="call-1" joined canManage />);
    expect(await screen.findByText(/indicator stays visible/)).toBeVisible();
    expect(screen.queryByRole("button", { name: "Stop recording" })).not.toBeInTheDocument();
  });

  it("consumes actual LiveKit transcription events only after the local captions toggle", async () => {
    const handlers = new Map<string, (...args: unknown[]) => void>();
    const room = { localParticipant: { identity: "self" }, remoteParticipants: new Map(), on: vi.fn((event, callback) => handlers.set(event, callback)), off: vi.fn((event) => handlers.delete(event)) } as unknown as Room;
    const client = api(page([], false));
    render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" joined room={room} />);
    expect(handlers.has(RoomEvent.TranscriptionReceived)).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Show captions" }));
    await waitFor(() => expect(handlers.has(RoomEvent.TranscriptionReceived)).toBe(true));
    await act(async () => { handlers.get(RoomEvent.TranscriptionReceived)?.([{ id: "segment-1", text: "A provider caption", final: true }]); });
    expect(await screen.findByText("A provider caption")).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Hide captions" }));
    expect(screen.queryByText("A provider caption")).not.toBeInTheDocument();
    expect(handlers.has(RoomEvent.TranscriptionReceived)).toBe(false);
  });

  it("retrieves saved transcripts with escaped text and clears content when access fails", async () => {
    const transcript = { ...recording, id: "transcript-1", kind: "transcript" as const, status: "available" as const, source_artifact_id: recording.id, content_type: "application/json" };
    const client = api(page([transcript]));
    vi.mocked(client.artifactTranscript).mockResolvedValue({ data: transcript, segments: [{ sequence: 0, start_ms: 1_000, end_ms: 2_000, text: "<script>private content</script>" }] });
    render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" />);
    fireEvent.click(await screen.findByRole("button", { name: "Read transcript" }));
    expect(await screen.findByText("<script>private content</script>")).toBeVisible();
    expect(document.querySelector(".meeting-saved-transcript script")).toBeNull();
    vi.mocked(client.meetingArtifacts).mockRejectedValue(new Error("Membership was revoked"));
    fireEvent.click(screen.getByRole("button", { name: "Delete transcript" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Membership was revoked");
    expect(screen.queryByText("<script>private content</script>")).not.toBeInTheDocument();
  });

  it("rejects an unchecked playback origin and prevents direct-media recording", async () => {
    const available = { ...recording, status: "available" as const };
    const client = api(page([available]));
    vi.mocked(client.artifactPlayback).mockResolvedValue({ data: available, download: { url: "https://attacker.invalid/capture.mp4", approved_origin: "https://approved.example.test" } });
    render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" joined canManage captureAllowed={false} />);
    fireEvent.click(await screen.findByRole("button", { name: "Play recording" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("could not be verified");
    expect(document.querySelector("video")).toBeNull();
    expect(screen.getByRole("button", { name: "Request recording consent" })).toBeDisabled();
  });
  it("requires a separate summary choice before capture and never reuses recording consent", async () => {
    const capture = { ...recording, my_consent: true, consent_accepted_count: 2, summary_requested: true, summary_policy_version: "meeting-summary-v1" as const, summary_consent_required_count: 2, summary_consent_accepted_count: 0, my_summary_consent: false };
    const client = api(page([capture]));
    render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" joined canManage />);
    expect(await screen.findByRole("button", { name: "Start recording" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "I separately consent to selected-quote summaries" }));
    await waitFor(() => expect(client.consentSummary).toHaveBeenCalledWith("conversation-1", "call-1", "recording-1", true));
    expect(client.startRecording).not.toHaveBeenCalled();
    expect(client.consentRecording).not.toHaveBeenCalled();
  });

  it("escapes selected quotes and clears them when current access cannot be refreshed", async () => {
    const artifact = { ...recording, id: "summary-1", kind: "summary" as const, status: "available" as const, source_artifact_id: "transcript-1" };
    const client = api(page([artifact]));
    vi.mocked(client.artifactSummary).mockResolvedValue({ data: artifact, summary: { method: "extractive_quotes", text: "<script>Restricted quote</script>", source_artifact_id: "transcript-1", source_sha256: "a".repeat(64), summary_sha256: "b".repeat(64), policy_version: "meeting-summary-v1" } });
    render(<MeetingArtifactsPanel api={client} conversationId="conversation-1" callId="call-1" />);
    fireEvent.click(await screen.findByRole("button", { name: "Read selected-quote summary" }));
    expect(await screen.findByText("<script>Restricted quote</script>")).toBeVisible();
    expect(document.querySelector(".meeting-artifacts script")).toBeNull();
    vi.mocked(client.meetingArtifacts).mockRejectedValue(new Error("Current authority revoked"));
    fireEvent.click(screen.getByRole("button", { name: "Delete summary" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Current authority revoked");
    expect(screen.queryByText("<script>Restricted quote</script>")).not.toBeInTheDocument();
  });

});
