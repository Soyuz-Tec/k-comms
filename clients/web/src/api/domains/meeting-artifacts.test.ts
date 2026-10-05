import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createMeetingArtifactsApi } from "./meeting-artifacts";
describe("meeting artifact routes", () => {
  it("escapes identities and sends explicit consent and transcript source without provider URLs", async () => {
    const request = vi.fn().mockResolvedValue({ data: { id: "artifact" } });
    const api = createMeetingArtifactsApi(request as ApiRequest);
    await api.consentRecording("conversation/other", "call?other", "artifact/other", false);
    expect(request).toHaveBeenLastCalledWith("/api/v1/conversations/conversation%2Fother/calls/call%3Fother/artifacts/artifact%2Fother/consent", { method: "POST", body: '{"accepted":false}' });
    await api.requestTranscript("conversation", "call", "source-id", "operation-1");
    expect(request).toHaveBeenLastCalledWith("/api/v1/conversations/conversation/calls/call/artifacts", { method: "POST", body: '{"kind":"transcript","source_artifact_id":"source-id","idempotency_key":"operation-1"}' });
  });
});
