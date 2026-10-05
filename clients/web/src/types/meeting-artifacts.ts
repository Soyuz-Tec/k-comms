import type { UploadDescriptor } from "./messaging";

export type MeetingArtifactStatus = "pending_consent" | "starting" | "recording" | "stopping" | "processing" | "available" | "failed" | "deleting" | "deleted";
export interface MeetingArtifact {
  id: string;
  conversation_id: string;
  call_id: string;
  meeting_id?: string | null;
  source_artifact_id?: string | null;
  transcript_language?: string | null;
  kind: "recording" | "transcript";
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
}
export interface MeetingArtifactPage {
  data: MeetingArtifact[];
  capabilities: MeetingArtifactCapabilities;
}
export interface TranscriptSegment { sequence: number; start_ms: number; end_ms: number; text: string }
export interface MeetingArtifactTranscript { data: MeetingArtifact; segments: TranscriptSegment[] }
export interface MeetingArtifactPlayback { data: MeetingArtifact; download: UploadDescriptor }
