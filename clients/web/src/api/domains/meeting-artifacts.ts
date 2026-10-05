import type { ApiRequest } from "../contracts";
import type { DataResponse } from "../../types/common";
import type { MeetingArtifact, MeetingArtifactPage, MeetingArtifactPlayback, MeetingArtifactTranscript, MeetingArtifactSummary } from "../../types/meeting-artifacts";

export function createMeetingArtifactsApi(request: ApiRequest) {
  const base = (conversationId: string, callId: string) => `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/artifacts`;
  const item = (conversationId: string, callId: string, id: string) => `${base(conversationId, callId)}/${encodeURIComponent(id)}`;
  const post = (path: string, body?: object) => request<DataResponse<MeetingArtifact>>(path, { method: "POST", ...(body ? { body: JSON.stringify(body) } : {}) }).then(response => response.data);
  return {
    meetingArtifacts: (conversationId: string, callId: string): Promise<MeetingArtifactPage> => request(base(conversationId, callId)),
    requestRecording: (conversationId: string, callId: string, operationId: string, summaryRequested = false) => post(base(conversationId, callId), { kind: "recording", idempotency_key: operationId, ...(summaryRequested ? { summary_requested: true } : {}) }),
    requestTranscript: (conversationId: string, callId: string, sourceArtifactId: string, operationId: string) => post(base(conversationId, callId), { kind: "transcript", source_artifact_id: sourceArtifactId, idempotency_key: operationId }),
    requestSummary: (conversationId: string, callId: string, sourceArtifactId: string, operationId: string) => post(base(conversationId, callId), { kind: "summary", source_artifact_id: sourceArtifactId, idempotency_key: operationId }),
    consentSummary: (conversationId: string, callId: string, id: string, accepted: boolean) => post(`${item(conversationId, callId, id)}/summary-consent`, { accepted, policy_version: "meeting-summary-v1" }),
    artifactSummary: (conversationId: string, callId: string, id: string): Promise<MeetingArtifactSummary> => request(`${item(conversationId, callId, id)}/summary`),
    consentRecording: (conversationId: string, callId: string, id: string, accepted: boolean) => post(`${item(conversationId, callId, id)}/consent`, { accepted }),
    startRecording: (conversationId: string, callId: string, id: string) => post(`${item(conversationId, callId, id)}/start`),
    stopRecording: (conversationId: string, callId: string, id: string) => post(`${item(conversationId, callId, id)}/stop`),
    artifactPlayback: (conversationId: string, callId: string, id: string): Promise<MeetingArtifactPlayback> => request(`${item(conversationId, callId, id)}/playback`),
    artifactTranscript: (conversationId: string, callId: string, id: string): Promise<MeetingArtifactTranscript> => request(`${item(conversationId, callId, id)}/transcript`),
    deleteMeetingArtifact: (conversationId: string, callId: string, id: string) => request<DataResponse<MeetingArtifact>>(item(conversationId, callId, id), { method: "DELETE" }).then(response => response.data)
  };
}
export type MeetingArtifactsApi = ReturnType<typeof createMeetingArtifactsApi>;
