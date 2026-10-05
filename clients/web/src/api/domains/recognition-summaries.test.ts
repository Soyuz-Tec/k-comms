import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createMeetingArtifactsApi } from "./meeting-artifacts";

describe("actual recognition and explicitly consented summary routes", () => {
  it("keeps ordinary recording consent separate from disclosed summary policy", async () => {
    const request = vi.fn().mockResolvedValue({ data: { id: "recording" } });
    const api = createMeetingArtifactsApi(request as ApiRequest);
    await api.requestRecording("conversation", "call", "operation");
    expect(JSON.parse(request.mock.calls.at(-1)![1].body)).toEqual({ kind: "recording", idempotency_key: "operation" });
    await api.requestRecording("conversation", "call", "disclosed-operation", true);
    expect(JSON.parse(request.mock.calls.at(-1)![1].body).summary_requested).toBe(true);
    await api.consentSummary("conversation", "call", "recording", false);
    expect(request).toHaveBeenLastCalledWith("/api/v1/conversations/conversation/calls/call/artifacts/recording/summary-consent", { method: "POST", body: JSON.stringify({ accepted: false, policy_version: "meeting-summary-v1" }) });
  });

  it("requests a derived summary from an actual transcript and reads its lineage DTO", async () => {
    const request = vi.fn().mockResolvedValue({ data: { id: "summary" } });
    const api = createMeetingArtifactsApi(request as ApiRequest);
    await api.requestSummary("conversation", "call", "transcript", "operation");
    expect(request).toHaveBeenLastCalledWith("/api/v1/conversations/conversation/calls/call/artifacts", { method: "POST", body: JSON.stringify({ kind: "summary", source_artifact_id: "transcript", idempotency_key: "operation" }) });
    await api.artifactSummary("conversation", "call", "summary");
    expect(request).toHaveBeenLastCalledWith("/api/v1/conversations/conversation/calls/call/artifacts/summary/summary");
  });
});
