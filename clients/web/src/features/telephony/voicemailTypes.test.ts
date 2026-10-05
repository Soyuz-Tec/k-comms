import { describe, expect, it } from "vitest";
import { approvedVoicemailPlayback } from "./voicemailTypes";
import type { VoicemailPlayback } from "./voicemailTypes";
const signed: VoicemailPlayback = { url: "https://media.example.test/t/voice.wav?versionId=exact", approved_origin: "https://media.example.test", development_http: false, expires_at: new Date(Date.now() + 120_000).toISOString(), expires_in: 120, content_type: "audio/wav" };
describe("voicemail playback boundary", () => {
  it("accepts only the currently approved storage origin and a nonempty pinned version", () => {
    expect(approvedVoicemailPlayback(signed)).toBe(true);
    for (const url of ["https://foreign.example.test/voice.wav?versionId=exact", "https://user:secret@media.example.test/voice.wav?versionId=exact", "https://media.example.test/voice.wav", "https://media.example.test/voice.wav?versionId=null", "javascript:alert(1)", "http://media.example.test/voice.wav?versionId=exact"]) expect(approvedVoicemailPlayback({ ...signed, url })).toBe(false);
    expect(approvedVoicemailPlayback({ ...signed, expires_at: "2000-01-01T00:00:00Z" })).toBe(false);
    expect(approvedVoicemailPlayback({ ...signed, approved_origin: "https://media.example.test/path" })).toBe(false);
  });
  it("allows explicit localhost development transport while rejecting an arbitrary HTTP host", () => {
    expect(approvedVoicemailPlayback({ ...signed, development_http: true, url: "http://localhost:9000/voice.wav?versionId=exact", approved_origin: "http://localhost:9000" })).toBe(true);
    expect(approvedVoicemailPlayback({ ...signed, development_http: true, url: "http://unsafe.example.test/voice.wav?versionId=exact", approved_origin: "http://unsafe.example.test" })).toBe(false);
  });
});
