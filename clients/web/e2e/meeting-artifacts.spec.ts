import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { conversationId, installWorkspace, userId } from "./mobile-ui-support";
import type { MeetingArtifact, MeetingArtifactPage } from "../src/types/meeting-artifacts";

const callId = "11111111-1111-4111-8111-111111111111";
const recording: MeetingArtifact = { id: "22222222-2222-4222-8222-222222222222", conversation_id: conversationId, call_id: callId, kind: "recording", status: "available", created_at: "2026-10-04T12:00:00Z", expires_at: "2099-11-04T12:00:00Z", content_type: "video/mp4", byte_size: 4, consent_required_count: 2, consent_accepted_count: 2, my_consent: true, can_manage: true };
const transcript: MeetingArtifact = { ...recording, id: "33333333-3333-4333-8333-333333333333", kind: "transcript", source_artifact_id: recording.id, content_type: "application/json" };

async function history(page: Page) {
  await installWorkspace(page);
  await page.route("**/api/v1/calls?**", route => {
    const recent = new URL(route.request().url()).searchParams.get("scope") === "recent";
    return route.fulfill({ json: { data: recent ? [{ id: callId, conversation_id: conversationId, started_by_user_id: userId, ended_by_user_id: userId, media_kind: "video", status: "ended", started_at: "2026-10-04T12:00:00Z", expires_at: "2026-10-04T20:00:00Z", ended_at: "2026-10-04T13:00:00Z", end_reason: "host_ended", duration_seconds: 3600, can_end: false }] : [], page: { limit: 25, has_more: false, next_cursor: null } } });
  });
}
function artifacts(data: MeetingArtifact[], enabled = true): MeetingArtifactPage {
  return { data, capabilities: { recording: enabled, recording_reason: "privacy_opt_in_required", participant_consent_required: true, persistent_transcript: enabled, persistent_transcript_reason: "qualified_provider_required", captions: "provider_events_only", automatic_capture: false } };
}

test.describe("post-meeting artifacts", () => {
  test("opens actual call history retrieval, explicitly generates and reads a saved transcript, and reports legal-hold deletion", async ({ page }) => {
    await history(page);
    let generated = false;
    let read = false;
    const base = `/api/v1/conversations/${conversationId}/calls/${callId}/artifacts`;
    await page.route("**/api/v1/conversations/*/calls/*/artifacts**", async route => {
      const path = new URL(route.request().url()).pathname;
      if (path === base && route.request().method() === "GET") return route.fulfill({ json: artifacts(generated ? [recording, transcript] : [recording]) });
      if (path === base && route.request().method() === "POST") {
        const body = route.request().postDataJSON();
        expect(body.kind).toBe("transcript"); expect(body.source_artifact_id).toBe(recording.id);
        expect(typeof body.idempotency_key).toBe("string"); generated = true;
        return route.fulfill({ status: 201, json: { data: transcript } });
      }
      if (path === `${base}/${transcript.id}/transcript`) {
        read = true;
        return route.fulfill({ json: { data: transcript, segments: [{ sequence: 0, start_ms: 1000, end_ms: 2000, text: "Approved meeting decision <script>" }] } });
      }
      if (path === `${base}/${transcript.id}` && route.request().method() === "DELETE") return route.fulfill({ status: 409, json: { error: { code: "artifact_legal_hold", detail: "A legal hold prevents deletion." } } });
      return route.fulfill({ status: 404, json: { error: { code: "not_found", detail: "Unknown artifact." } } });
    });
    await page.goto("/app/calls");
    await page.getByRole("button", { name: "Recent", exact: true }).click();
    await page.getByRole("button", { name: /^View recordings and transcripts/ }).click();
    await expect(page.getByRole("button", { name: "Generate transcript" })).toBeVisible();
    expect(generated).toBe(false); expect(read).toBe(false);
    await page.getByRole("button", { name: "Generate transcript" }).click();
    await page.getByRole("button", { name: "Read transcript" }).click();
    await expect(page.getByText("Approved meeting decision <script>")).toBeVisible();
    await expect(page.locator(".meeting-saved-transcript script")).toHaveCount(0);
    await page.getByRole("button", { name: "Delete transcript" }).click();
    await expect(page.getByRole("alert")).toContainText("A legal hold prevents deletion.");
    expect(generated).toBe(true); expect(read).toBe(true);
  });

  test("shows default-off provider state and recovers a failed post-meeting read", async ({ page }) => {
    await history(page);
    let failed = true;
    await page.route("**/api/v1/conversations/*/calls/*/artifacts", route => {
      if (failed) return route.fulfill({ status: 503, json: { error: { code: "provider_unavailable", detail: "Artifact retrieval is temporarily unavailable." } } });
      return route.fulfill({ json: artifacts([], false) });
    });
    await page.goto("/app/calls");
    await page.getByRole("button", { name: "Recent", exact: true }).click();
    await page.getByRole("button", { name: /^View recordings and transcripts/ }).click();
    await expect(page.getByRole("alert")).toContainText("Artifact retrieval is temporarily unavailable.");
    failed = false;
    await page.getByRole("button", { name: "Try again", exact: true }).click();
    await expect(page.getByText(/Recording is off/)).toBeVisible();
    await expect(page.getByText("No saved artifacts for this call.")).toBeVisible();
    await expect(page.getByRole("button", { name: "Request recording consent" })).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Show captions" })).toHaveCount(0);
  });
});
