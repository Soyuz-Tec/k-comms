import { describe, expect, it, vi } from "vitest";
import { meetingCallApi } from "./meetingCallApi";

describe("meeting call lobby API", () => {
  it("checks occurrence policy for both a new call and an existing call join", async () => {
    const startMeeting = vi.fn().mockResolvedValue({ data: { id: "scheduled-call" } });
    const startCall = vi.fn();
    const joinCall = vi.fn();
    const api = meetingCallApi({ startMeeting, startCall, joinCall }, { meetingId: "meeting-1", occurrenceId: "occurrence-2" }, "video");
    await api.startCall?.("conversation-1", "audio");
    await api.joinCall?.("conversation-1", "unrelated-call");
    expect(startMeeting.mock.calls).toEqual([["meeting-1", "occurrence-2", "audio"], ["meeting-1", "occurrence-2", "video"]]);
    expect(startCall).not.toHaveBeenCalled();
    expect(joinCall).not.toHaveBeenCalled();
  });

  it("keeps transport and call controls bound to the original authenticated client", async () => {
    class Client {
      id = "client";
      startMeeting = vi.fn();
      async socketTicket() { return { ticket: this.id, expires_in: 30 }; }
      endCall = vi.fn(function(this: Client) {
        return Promise.resolve({ id: this.id, conversation_id: "conversation-1", media_kind: "audio" as const, status: "ended" as const, started_by_user_id: "user-1", started_at: "2026-10-04T09:00:00Z", expires_at: "2026-10-04T10:00:00Z", ended_at: "2026-10-04T09:30:00Z", can_end: false });
      });
    }
    const original = new Client();
    const api = meetingCallApi(original, { meetingId: "m", occurrenceId: "o" }, "audio");
    await expect(api.socketTicket?.()).resolves.toEqual({ ticket: "client", expires_in: 30 });
    await expect(api.endCall?.("conversation-1", "call-1")).resolves.toMatchObject({ id: "client" });
  });
});
