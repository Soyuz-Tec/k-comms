import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createVoicemailApi } from "./voicemail";
describe("voicemail API", () => {
  it("escapes identities, preserves bounded cursors and never sends provider recording names", async () => {
    const request = vi.fn().mockResolvedValue({ data: {} });
    const api = createVoicemailApi(request as ApiRequest);
    await api.voicemails({ limit: 10, cursor: "cursor&next" });
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/voicemails?limit=10&cursor=cursor%26next");
    await api.voicemailPlayback("voice/other?path");
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/voicemails/voice%2Fother%3Fpath/playback");
    await api.markVoicemailRead("voice");
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/voicemails/voice/read", { method: "POST" });
    await api.deleteVoicemail("voice");
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/voicemails/voice", { method: "DELETE" });
  });
});
