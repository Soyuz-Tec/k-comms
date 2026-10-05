import type { UploadDescriptor } from "./messaging";

export type MeetingArtifactStatus = "pending_consent" | "starting" | "recording" | "stopping" | "processing" | "available" | "failed" | "deleting" | "deleted";
export interface MeetingArtifact {
  id: string;
  conversation_id: string;
  call_id: string;
  meeting_id?: string | null;
  source_artifact_id?: string | null;
  transcript_language?: string | null;
  kind: "recording" | "transcript" | "summary";
  summary_requested?: boolean;
  summary_policy_version?: "meeting-summary-v1" | null;
  summary_consent_required_count?: number;
  summary_consent_accepted_count?: number;
  my_summary_consent?: boolean | null;
  can_withdraw_summary_consent?: boolean;
  recognition_mode?: "post_recording" | null;
  recognition_model_sha256?: string | null;
  status: MeetingArtifactStatus;
  created_at: string;
  started_at?: string | null;
  ended_at?: string | null;
  expires_at: string;
  failure_code?: string | null;
  consent_required_count: number;
  consent_accepted_count: number;
  my_consent: boolean | null;
  can_manage: boolean;
  byte_size?: number | null;
  content_type: string;
}
export interface MeetingArtifactCapabilities {
  recording: boolean;
  recording_reason: string;
  participant_consent_required: true;
  persistent_transcript: boolean;
  persistent_transcript_reason: string;
  captions: "provider_events_only";
  automatic_capture: false;
  recognition_mode?: "post_recording";
  explicit_summary?: boolean;
  summary_consent_required?: true;
  summary_post_call_only?: true;
}
export interface MeetingArtifactPage {
  data: MeetingArtifact[];
  capabilities: MeetingArtifactCapabilities;
}
export interface TranscriptSegment { sequence: number; start_ms: number; end_ms: number; text: string }
export interface MeetingArtifactTranscript { data: MeetingArtifact; segments: TranscriptSegment[] }
export interface MeetingArtifactPlayback { data: MeetingArtifact; download: UploadDescriptor }

export interface MeetingArtifactSummary { data: MeetingArtifact; summary: { method: "extractive_quotes"; text: string; source_artifact_id: string; source_sha256: string; summary_sha256: string; policy_version: "meeting-summary-v1" } }
